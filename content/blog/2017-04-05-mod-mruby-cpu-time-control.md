---
author: "Takuma Kume"
title: "mod_mrubyを使ってリクエスト毎のCPU使用時間に応じたアクセス制限を行う"
linktitle: "mod_mrubyを使ってリクエスト毎のCPU使用時間に応じたアクセス制限を行う"
date: 2017-04-05T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "mod_mruby"]
---

### はじめに

お久しぶりです。
ペパボの久米です。
本日はmrubyを利用したWEBサーバのCPU使用率を元にしたアクセス制御例をご紹介します。

具体的には以下のような制御を行いたい。

<img src="/img/2017-04-05/ru_limit.jpg" alt="" width="750" height="563" class="alignnone size-large wp-image-372" />

- 複数ドメイン環境下において、リクエスト毎に使われるCPU使用時間を元にサーバの負荷が高い場合にvhost単位の制限を行う。
  - サーバの負荷の判断はLoadAveを元に行う。
  - CPU使用時間はリクエスト開始から処理終了までの合計が必要なので、判定に使うCPU時間は前回のリクエストの情報を使う。

### 実装にあたって使用する主なソフトウェア

- [mod_mruby](https://github.com/matsumotory/mod_mruby) を導入した Apache (本エントリの内容は、おそらく [ngx_mruby](https://github.com/matsumotory/ngx_mruby) でも動作する)
  - 詳しくは過去のエントリを御覧ください。 ([httpd + mod_mrubyでプログラマブルなWEBサーバを構築する](/blog/2016-07-26-install-mod-mruby/))
- [mruby-resource](https://github.com/harasou/mruby-resource)
  - 今回は `getrusage(2)` の機能を利用した、CPU使用時間の取得を行うために利用します。

### 実装

**本エントリでは httpd2.2 + mod_mrubyを用いて行います。**

#### 事前準備

- mod_mrubyのbuildはbuild_config.rbに以下のような追加をしてビルドしておく。

```diff
--- /usr/local/src/mod_mruby/build_config.rb.orig	2017-04-04 10:15:31.152370251 +0000
+++ /usr/local/src/mod_mruby/build_config.rb	2017-04-04 10:16:15.034296969 +0000
@@ -43,6 +43,8 @@
   # conf.gem :github => 'matsumoto-r/mruby-capability'
   # conf.gem :github => 'matsumoto-r/mruby-cgroup'

+  conf.gem :github => 'harasou/mruby-resource'
+
   # C compiler settings
   conf.cc do |cc|
     if ENV['BUILD_TYPE'] == "debug"
```

#### メイン実装

##### httpd.conf

以下の内容を追加する。

```
LoadModule mruby_module modules/mod_mruby.so

<IfModule mod_mruby.c>
  mrubyPostConfigMiddle        /etc/httpd/conf.d/mruby/init.rb cache
  <FilesMatch ^.*\.php$>
    mrubyAccessCheckerMiddle   /etc/httpd/conf.d/mruby/begin.rb cache
    mrubyLogTransactionMiddle  /etc/httpd/conf.d/mruby/end.rb cache
  </FilesMatch>
</IfModule>
```

##### init.rb

- プロセス起動時に1度だけ実行される。
- 各リクエストで利用するcacheやmutexを作成して、Userdataに格納し各Workerから参照できるようにする。(都度初期化するより大幅にパフォーマンス向上する)
- Userdata.new.shared_cache
  - vhost毎に最後のリクエスト終了後のCPU使用時間を保持する。
- Userdata.new.shared_mutex
  - 処理の最後に上記Cacheに書き込む際の競合を防止する。

```ruby
Server = get_server_class

begin
  Userdata.new.shared_cache = Cache.new :namespace => "resource-limiter"
rescue => e
  raise "localmemcache init failed on #{__LINE__}: #{e}"
end

begin
  Userdata.new.shared_mutex = Mutex.new :global => true
rescue => e
  raise "mutex init failed on #{__LINE__}: #{e}"
end
```

##### begin.rb

- リクエスト毎に最初に実行される。
- LoadAvgが一定以上であれば以下のことをする。
  - 最後のリクエスト終了時点のCPU使用時間が一定を超えていれば503エラーを返す。
  - それ以外は通常の処理を行う。

```ruby
LOADAVG_THRESHOLD = 50
RU_UTIME_LIMIT    = 20

Server = get_server_class

# get this server loadavg for 3 min
loadavg = IO.read('/proc/loadavg').split(' ')[0].to_f

vhost = Server::Request.new.hostname

if loadavg > LOADAVG_THRESHOLD
  Server.errlogger Server::LOG_INFO, "loadavg is over threshold. LOADAVG_THRESHOLD:#{LOADAVG_THRESHOLD} loadavg:#{loadavg} hostname:#{vhost}"
  begin
    cache = Userdata.new.shared_cache
    last_ru_utime = cache[vhost].to_f
    if last_ru_utime > RU_UTIME_LIMIT
      Server.errlogger Server::LOG_INFO, "ru_utime is over limit (return 503). limit:#{RU_UTIME_LIMIT} last_ru_utime:#{last_ru_utime} hostname:#{vhost}"
      Server.return Server::HTTP_SERVICE_UNAVAILABLE
    else
      Server.return Server::DECLINED
    end
  rescue => e
    Server.errlogger Server::LOG_ERROR "failed on #{__LINE__}: #{e}"
    Server.return Server::DECLINED
  end
else
  Server.errlogger Server::LOG_INFO, "loadavg not over threshold. skip... LOADAVG_THRESHOLD:#{LOADAVG_THRESHOLD} loadavg:#{loadavg} hostname:#{vhost}"
  Server.return Server::DECLINED
end
```

##### end.rb

- コンテンツ処理、レスポンスが終了した時に実行される。
- CPU使用時間をvhostをキーに記録します。
- getrusage(RUSAGE_SELF)
  - mruby-resourceを用いてgetrusageを実行します。
  - ru_utime = rusage[:ru_utime]
    - 使用されたユーザCPUの時間を取得します。

```ruby
include Resource

Server = get_server_class

cache = Userdata.new.shared_cache
mutex = Userdata.new.shared_mutex
vhost = Server::Request.new.hostname

rusage = getrusage(RUSAGE_SELF)
ru_utime = rusage[:ru_utime]

timeout = mutex.try_lock_loop(50000) do
  begin
    cache[vhost] = ru_utime.to_s
    Server.errlogger Server::LOG_INFO, "Recorded ru_utime. ru_utime:#{ru_utime} hostname:#{vhost}"
  rescue => e
    raise "failed on #{__LINE__}: #{e}"
  ensure
    mutex.unlock
  end
end
if timeout
  Server.errlogger Server::LOG_WARNING, "Get timeout lock mutex"
end
```

### 実行結果

- テストのため閾値を大幅に下げます。(begin.rb)

```ruby
#LOADAVG_THRESHOLD = 50
LOADAVG_THRESHOLD = 0.001
#RU_UTIME_LIMIT    = 20
RU_UTIME_LIMIT    = 0.001
```

- 負荷が低い時

```
# curl http://hoge.local/index.php => 通常表示
[Tue Apr 04 23:54:11 2017] [info] loadavg not over threshold. skip... LOADAVG_THRESHOLD:0.001 loadavg:0 hostname:hoge.local
[Tue Apr 04 23:54:11 2017] [info] Recorded ru_utime. ru_utime:0.005999 hostname:hoge.local
```

- 負荷が高い時

```
# curl http://hoge.local/index.php => 503エラー
[Tue Apr 04 23:54:34 2017] [info] loadavg is over threshold. LOADAVG_THRESHOLD:0.001 loadavg:0.06 hostname:hoge.local
[Tue Apr 04 23:54:34 2017] [info] ru_utime is over limit (return 503). limit:0.001 last_ru_utime:0.010998 hostname:hoge.local
[Tue Apr 04 23:54:34 2017] [info] Recorded ru_utime. ru_utime:0.007998 hostname:hoge.local
```

このように指定したCPU使用時間を超えた場合にエラーを返すことができました。
