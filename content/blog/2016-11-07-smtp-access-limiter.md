---
author: "Takuma Kume"
title: "pmilterで任意のToやFrom、ヘッダ、文字列をキーにメールの通数制御を行う"
linktitle: "pmilterで任意のToやFrom、ヘッダ、文字列をキーにメールの通数制御を行う"
date: 2016-11-07T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "pmilter"]
---

### はじめに

先日は 「[pmilter + postfixでプログラマブルなSMTPサーバを作る（入門編）](/blog/2016-11-06-install-pmilter/)」の記事で[pmilter](https://github.com/matsumotory/pmilter)の環境構築を行いました。
本エントリでは、[pmilter](https://github.com/matsumotory/pmilter)を活用して実際にメールの通数を制御するソフトウェアを作成しました。

[smtp-access-limiter](https://github.com/takumakume/smtp-access-limiter) (まだプロトタイプ)

### smtp-access-limiterとは

任意のToやFrom、文字列などをキーとして、一定期間のメールの通数をカウントするソフトウェアです。
キーとして利用するのは、pmilterの各SMTPプロトコルフローの中で取得できるパラメータです。

また、pmilterの性質上メールがキューに入る前に処理されるので、処理できないメールを効率よく制御することができます。

### ソフトウェアの紹介にあたって

今回は、pmilterで取得できるパラメータの中でも RCPT TOのフェーズで取得できるenvelop toからドメイン名を取得して、それをキーとします。
"RCPT TO: hoge@foo.com" であれば "foo.com" をキーとする。

その上で、一定期間内に同一の送信先のドメインに送れるメール通数の制御を行ってみます。

### Let's development!!

##### pmilterのビルド

pmilterの "src/mruby/build_config.rb" でpmilterで実行するmruby scriptで使うmgemの設定を行うところがあります。今回は以下のmgemを利用しますので設定してpmilterを再ビルドします。

- matsumotory/mruby-mutex
- matsumotory/mruby-localmemcache

```diff
# git diff src/mruby/build_config.rb
diff --git a/src/mruby/build_config.rb b/src/mruby/build_config.rb
index bc9e69e..c157a37 100644
--- a/src/mruby/build_config.rb
+++ b/src/mruby/build_config.rb
@@ -18,6 +18,8 @@ MRuby::Build.new do |conf|
   # conf.gem 'examples/mrbgems/c_and_ruby_extension_example'
   # conf.gem :github => 'masuidrive/mrbgems-example', :checksum_hash => '76518e8aecd131d047378448ac8055fa29d974a9'
   # conf.gem :git => 'git@github.com:masuidrive/mrbgems-example.git', :branch => 'master', :options => '-v'
+  conf.gem :github => 'matsumotory/mruby-mutex'
+  conf.gem :github => 'matsumotory/mruby-localmemcache'

   # include the default GEMs
   conf.gembox 'default'
```

再ビルド

```sh
make mruby
make
```

##### pmilterの設定

- pmilter.conf

```
[server]
# hoge.sock or ipaddree:port
listen = "/var/tmp/pmilter.sock"
timeout = 7210
log_level = "debug"
mruby_handler = true
listen_backlog = 128
debug = 1

[handler]
# envelope recipient filter handler
mruby_envrcpt_handler = "handler/access_limiter.rb"
```

- handler/access_limiter.rb

```ruby
global_mutex = Mutex.new :global => true

class AccessLimiter
  def initialize config
    @current_time = Time.new.localtime.to_i
    @counter_kvs = Cache.new :namespace => "smtp_access_limiter"
    @counter_key = config[:target]
    raise "config[:target] is nil" unless @counter_key
    @interval_time = config[:interval_time].to_i
    raise "config[:interval_time] is nil" unless config[:interval_time]
  end

  def cleanup
    ctime = @counter_kvs["create_time_#{@counter_key}"].to_i
    return false if ctime == 0
    if (ctime + @interval_time) < @current_time
      @counter_kvs.delete("create_time_#{@counter_key}")
      @counter_kvs.delete(@counter_key)
      true
    else
      false
    end
  end

  def current
    @counter_kvs[@counter_key]
  end

  def increment
    cur = current.to_i
    if cur == 0
      @counter_kvs["create_time_#{@counter_key}"] = @current_time.to_s
    end
    @counter_kvs[@counter_key] = (cur + 1).to_s
  end
end

#-------------------------
# ここから下のコードを書き換えて制御単位を変える。
# この例ではenvelope toのドメイン単位で送信制御を行っている。
#-------------------------

# 一定期間内に許可する通数
threshold = 10

# envelope_toからドメイン部分を抽出
target = Pmilter::Session.new.envelope_to.split("@")[1]

config = {
  :target => target,
  # 期間指定(秒)
  :interval_time => 60
}
limiter = AccessLimiter.new(config)
status = limiter.cleanup
p "access_limiter: cleanup counter #{target} interval_time: #{interval_time}" if status

timeout = global_mutex.try_lock_loop(50000) do
  begin
    limiter.increment
    p "access_limiter: increment #{target} current: #{limiter.current} threshold: #{threshold}"
    if limiter.current.to_i > threshold
      p "access_limiter: reject #{target} threshold: #{threshold}"
      Pmilter.status = Pmilter::SMFIS_REJECT
    end
  rescue => e
    p "access_limiter: increment error #{target} #{e}"
  ensure
    global_mutex.unlock
  end
  if timeout
    "access_limiter: get timeout lock, #{target}"
  end
end
```

- メールが送信されて、rcpt toが実行されたときにこのソースコードが実行される。
- envelope to の ドメイン名が抽出され、それをキーとしてKVS上のカウンターをインクリメントする。
- インクリメント時に0->1になったときだけ、cureate_time_DOMAINのキーを作成し、時刻を記録する。
- インクリメント処理の前に、cureate_time_DOMAINが指定したinterval_timeを経過していた場合はカウンターを削除する。

##### 動作

hoge@pmilter.localへメールを送っていきます。

- 1通目

```
"access_limiter: increment pmilter.local current: 1 threshold: 10"
```

- 2通目

```
"access_limiter: increment pmilter.local current: 2 threshold: 10"
```

- 11通目 (ここからRejectされている)

```
"access_limiter: increment pmilter.local current: 11 threshold: 10"
"access_limiter: reject pmilter.local threshold: 10"
```

- 1分経過後の1通目 (通数カウントがリセットされている)

```
"access_limiter: cleanup counter pmilter.local"
"access_limiter: increment pmilter.local current: 1 threshold: 10"
```

### 今後について

- smtp-access-limiterはまだプロトタイプなので、これからテストの作成やパフォーマンス試験などを行う。
- 現段階で動作ログが標準出力のみなので、ログ出力できるようにする。
- 現在すべてのキーに対して同じ閾値しか設定できないので、その設定を外出しし、キー毎に設定できるようにする。
- このソフトウェアの構成では、サーバ内に閉じたKVSを使ってメール通数のカウントを行っている。メールシステム全体のメール通数カウントを行っていきたいとも考えているのでredisなどのネットワーク越しのKVSを使って全サーバでメール通数を共有できるようなものも開発予定。
