---
author: "Takuma Kume"
title: "ngx_mrubyでmemcachedやmysqldのコネクションを使いまわす"
linktitle: "ngx_mrubyでmemcachedやmysqldのコネクションを使いまわす"
date: 2016-07-14T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "ngx_mruby"]
---

### はじめに

どうも、GMOペパボ　インフラエンジニア　正規雇用となりました久米です。

以下のエントリでngx_mrubyを用いたリバースプロキシを構築しました。
[CentOS6で ngx_mruby + mruby-memcached + mruby-mysql をインストール](/blog/2016-05-10-ngx-mruby-reverse-proxy/)
[ngx_mrubyで転送先を外部参照するリバースプロキシを構築する](/blog/2016-04-11-try-install-ngx-mruby/)

本エントリでは、ここまで作ってきたリバースプロキシの性能向上をするために
以下のことを行います。

1. Workerが起動したときに、mysqldやmemcachedと接続しコネクションを保持する。
2. リクエスト毎に行っていた接続処理を保持したコネクションを使い回すことで効率化を図る。

上記を実現するために以下の機能を使います。

[matsumoto-r/mruby-userdata](https://github.com/matsumoto-r/mruby-userdata)

これをngx_mrubyに組み込むことで（デフォルトのbuild_config.rbに組み込まれている。）
Worker単位でデータを保持し他のmrubyスクリプトからデータの出し入れをすることができるようになります。

参考までにmruby-userdataを利用するためにはngx_mrubyをビルドする時にbuild_config.rbに以下が記載されておく必要があります。

```ruby
conf.gem :github => 'matsumoto-r/mruby-userdata'
```

### Let’s development!!

##### nginx.conf (抜粋)

```
 :　(略)
http {
    : (略)
    mruby_init_worker /usr/local/nginx/lib/mruby_init_worker.rb;
    mruby_exit_worker /usr/local/nginx/lib/mruby_exit_worker.rb;

    server {

        listen 80;

        location / {
	        resolver              127.0.0.1;
	        mruby_set             $proxy_pass /usr/local/nginx/lib/mruby_get_proxypass.rb　cache;
	        proxy_pass            http://$proxy_pass;
	        proxy_http_version    1.1;
	        proxy_set_header      host $host;
	        proxy_set_header      Connection "";
	        proxy_set_header      X-Forwarded-For $proxy_add_x_forwarded_for;
	        proxy_set_header      X-Forwarded-Host $host;
	        proxy_set_header      X-Forwarded-Server $host;
	        proxy_set_header      X-Real-IP $remote_addr;
        }

    }
}
```

```
mruby_init_worker /usr/local/nginx/lib/mruby_init_worker.rb;
```

これはngx_mrubyのWorkerが起動した時に実行されるスクリプトです。
本検証では、mysqldとmemcachedへの接続と、コネクションをmruby-userdataで内部に格納する役割を持ちます。

```
mruby_exit_worker /usr/local/nginx/lib/mruby_exit_worker.rb;
```

これはngx_mrubyのWorkerが修了時に実行されるスクリプトです。
本検証では、mysqldとmemcachedのコネクションをクローズする役割を持ちます。

```
mruby_set  $proxy_pass /usr/local/nginx/lib/mruby_get_proxypass.rb　cache;
proxy_pass http://$proxy_pass;
```

これは、リクエスト毎に実行されproxy_passとなるドメインをmemcachedやmysqldから取得する役割を持ちます。
cacheというオプションをつけることで、mrubyスクリプトのコンパイルコストを削減します。
(しかし、mrubyスクリプトを修正した場合にnginx restartが必要になります。)

##### mruby_init_worker.rb

```ruby
#!mruby

# memcachedの接続設定
memcached_server = "192.168.100.31:11211"

# mysqldの接続設定
mysqld_server    = "192.168.100.21"
mysqld_user      = "root"
mysqld_password  = "root123"
mysqld_database  = "domains"

#
# メイン処理
#

# memcachedに接続
memcached = Memcached.new memcached_server

if memcached != nil then
	Userdata.new("memcached_#{Process.pid}").memcached_connection = memcached
end

# mysqldに接続
mysqld = MySQL::Database.new(mysqld_server, mysqld_user, mysqld_password, mysqld_database)

if mysqld != nil then
	Userdata.new("mysqld_#{Process.pid}").mysqld_connection = mysqld
end
```

```ruby
Userdata.new("memcached_#{Process.pid}").memcached_connection
```

上記のようにコネクションをmruby-userdataを利用して格納する。
これで、コネクションをWorker内の他のmrubyスクリプトから取り出すことができる。

##### mruby_exit_worker.rb

```ruby
#!mruby

#
# メイン処理
#

# mruby-userdataのmemcachedのオブジェクト
memcached = Userdata.new("memcached_#{Process.pid}").memcached_connection

# mruby-userdataのmysqldのオブジェクト
mysqld = Userdata.new("mysqld_#{Process.pid}").mysqld_connection

# Close memcached connection
if memcached != nil then
    Userdata.new("memcached_#{Process.pid}").memcached_connection.close
end

# Close mysqld connection
if mysqld != nil then
    Userdata.new("mysqld_#{Process.pid}").mysqld_connection.close
end
```

##### mruby_get_proxypass.rb

```ruby
#!mruby

# memcachedの接続設定
memecached_server = "192.168.100.31:11211"

# mysqldの接続設定
mysqld_server      = "192.168.100.21"
mysqld_user        = "root"
mysqld_password    = "root123"
mysqld_database    = "domains"

# mruby_set用の変数初期化
proxy_pass = ''

#
# メイン処理
#

# mruby-userdataのmemcachedのオブジェクト
memcached = Userdata.new("memcached_#{Process.pid}").memcached_connection

# mruby-userdataのmysqldのオブジェクト
mysqld = Userdata.new("mysqld_#{Process.pid}").mysqld_connection

# Nginx variables
v = Nginx::Var.new

# request domainからホストされているサーバを照会する。
Nginx.return -> do

    # memcachedのコネクションが切れている場合は接続する。(mruby-userdataに格納する。)
    if memcached == nil then
        Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: trying to connect to memcached. host=" + memecached_server
        memcached = Memcached.new memecached_server
        Userdata.new("memcached_#{Process.pid}").memcached_connection = memecached
    end

    # memcachedからproxy_passを取得するし格納する。
    proxy_pass = memcached.get v.http_host

    # memcachedからproxy_passが取得できた場合は処理を抜ける。
    if proxy_pass != nil then
        Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: memcached: req=" + v.http_host + " res=" + proxy_pass
        return Nginx::DECLINED
    end

    # mysqldのコネクションが切れている場合は接続する。(mruby-userdataに格納する。)
    Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: trying to connect to mysqld. host=" + mysqld_server
    mysqld = MySQL::Database.new(mysqld_server, mysqld_user, mysqld_password, mysqld_database)
    Userdata.new("mysqld_#{Process.pid}").mysqld_connection = mysqld

    # mysqldからproxy_passを取得する。
	begin
        mysql_result = mysqld.execute("SELECT host FROM domain WHERE domain = ? LIMIT 1", "#{v.http_host}")
	rescue
	    # mysqldのコネクションが切れている場合は接続する。(mruby-userdataに格納する。
	    Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: trying to connect to mysqld. host=" + mysqld_server
        Userdata.new("mysqld_#{Process.pid}").mysqld_connection = mysqld
        retry
	end

    # mysqldから結果が帰ってくればproxy_passに格納する。
    if mysql_result != nil then
        proxy_pass = mysql_result.next[0]
        mysql_result.close
    end

    # mysqldからproxy_passが取得できれば処理を抜ける。
    if proxy_pass != nil then
        Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: mysqld: req=" + v.http_host + " res=" + proxy_pass

        # memcachedにproxy_passを格納する。
        memcached.set v.http_host, proxy_pass
        Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: memcached: create cache key=" + v.http_host + " val=" + proxy_pass

        return Nginx::DECLINED
    end

    # 存在しないドメインをリクエストされているためログを出力して503エラーを返す。
    Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: request host is not found. req=" + v.http_host
    return Nginx::HTTP_SERVICE_UNAVAILABLE

end.call

proxy_pass
```

```ruby
Nginx.return -> do
 (処理)
end.call
```

このようにラムダ的な書き方になっているのは、mrubyはreturnのように途中でプログラムから抜けることができないため最後まで処理が実行されてしまうからである。
上記のような書き方をすることで一般的な関数のように、条件によって処理を抜けるような振る舞いをすることができる。

これには弊社の[@matsumotory](https://twitter.com/matsumotory)さんの紹介により以下のブログを参考にして実装した。

[ngx_mrubyを使って特定ホスト以外からのアクセスをメンテナンス画面にする](http://lamanotrama.hateblo.jp/entry/2015/08/02/005930)

ここの実装は例えばmysqldやmemcachedのサーバがrestartされるなどしてコネクションを失ってしまった時のために、接続の有効性を確認→無効であれば接続してmruby-userdataで格納。ということをしている。

```ruby
# mysqldからproxy_passを取得する。
begin
    mysql_result = mysqld.execute("SELECT host FROM domain WHERE domain = ? LIMIT 1", "#{v.http_host}")
rescue
    # mysqldのコネクションが切れている場合は接続する。(mruby-userdataに格納する。
    Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: trying to connect to mysqld. host=" + mysqld_server
    Userdata.new("mysqld_#{Process.pid}").mysqld_connection = mysqld
    retry
end
```

上記のように、mysqldのクエリ実行に失敗した場合にmysqldに再接続してリトライするようにしている。
単純に"mysql_connection != nil ..." のように評価するだけでは意図した動作をしなかった。

##### 動作検証

以下のようなコマンドをmysqldサーバ、memcachedサーバで実行してコネクションをモニタリングする。

```sh
watch -d "netstat -tanp | grep ngx_mrubyサーバのIPアドレス"
```

nginxの　error_log　も　tail -f　などでモニタリングする。

###### nginxを起動する。

```sh
# nginx
/etc/init.d/nginx start

# mysqld
tcp        0	  0 192.168.100.21:3306         192.168.100.10:51528        ESTABLISHED 6029/mysqld

# memcached
こちらは最初のgetやsetメソッドが実行されないとコネクションが張られない模様。
```

接続時にmysqldのコネクションが張られたことが分かった。
次はこのコネクションを使い回す。

###### ngx_mruby経由でWEBサイトにアクセスしてみる。

1回目のアクセス

```sh
# クライアント
curl http://site-a.local/

# nginx
2016/07/13 15:16:09 [info] 26391#0: *1 mruby_get_proxypass: mysqld: req=site-a.local res=web1.local, client: 192.168.100.10, server: , request: "GET / HTTP/1.1", host: "site-a.local"
2016/07/13 15:16:09 [info] 26391#0: *1 mruby_get_proxypass: memcached: create cache key=site-a.local val=web1.local, client: 192.168.100.10, server: , request: "GET / HTTP/1.1", host: "site-a.local"

# memcached
tcp        0	  0 192.168.100.31:11211        192.168.100.10:47983        ESTABLISHED 28027/memcached

# mysqld
tcp        0	  0 192.168.100.21:3306         192.168.100.10:51532        ESTABLISHED 6029/mysqld
```

- memcachedのコネクションが接続された。
- mysqldのコネクションが使いまわされている。
- mysqldから"site-a.local"のホスト先である"web1.local"が取得されていて、それをmemachedに書き込んでいる。

２回目のアクセス

```sh
# クライアント
curl http://site-a.local/

# nginx
2016/07/13 15:28:44 [info] 26391#0: *4 mruby_get_proxypass: memcached: req=site-a.local res=web1.local, client: 192.168.100.10, server: , request: "GET / HTTP/1.1", host: "site-a.local"

# memcached
tcp        0	  0 192.168.100.31:11211        192.168.100.10:47983        ESTABLISHED 28027/memcached

# mysqld
tcp        0	  0 192.168.100.21:3306         192.168.100.10:51532        ESTABLISHED 6029/mysqld
```

- memcachedのコネクションが使いまわされている。
- mysqldのコネクションが使いまわされている。
- mysqldから"site-a.local"のホスト先である"web1.local"が１回目で書き込んだmemcachedのキャッシュから取得している。

mysqld memcached を restart する。

```sh
# mysqld
/etc/init.d/mysqld restart

# memcached
/etc/init.d/memcached restart
```

再度アクセスする。

```sh
2016/07/13 16:06:49 [info] 26684#0: *1 mruby_get_proxypass: trying to connect to mysqld. host=192.168.100.21, client: 192.168.100.10, server: , request: "GET / HTTP/1.1", host: "site-a.local"
2016/07/13 16:06:49 [info] 26684#0: *1 mruby_get_proxypass: mysqld: req=site-a.local res=web1.local, client: 192.168.100.10, server: , request: "GET / HTTP/1.1", host: "site-a.local"
2016/07/13 16:06:49 [info] 26684#0: *1 mruby_get_proxypass: memcached: create cache key=site-a.local val=web1.local, client: 192.168.100.10, server: , request: "GET / HTTP/1.1", host: "site-a.local"
```

- mysqldと再接続している。

### 今後の課題

- コネクションを使いまわせることが確認できたので、それをしない場合とでどの程度パフォーマンスが向上したのかを測定する。
- 現在の実装だと複数のmrubyスクリプトで同じmemcachedのIPアドレスなどの設定を持っている。これをどうにか設定ファイルなどに切り出せないか？もしくはこの設定すらもmruby_init_workerでmruby-userdataを使って設定情報を保持するでもいい気もする。

### 参考文献

- [matsumoto-r/mruby-userdata](https://github.com/matsumoto-r/mruby-userdata)
- [ngx_mrubyを使って特定ホスト以外からのアクセスをメンテナンス画面にする](http://lamanotrama.hateblo.jp/entry/2015/08/02/005930)
- [ngx_mrubyインストール後入門 - ngx_mrubyによるnginx変数の扱い](http://qiita.com/matsumotory/items/43f2918c5ef5efd2d4d8)
- [mod_mrubyとngx_mrubyの設計思想とスクリプト間でオブジェクトを共有するためのアーキテクチャ概論](http://qiita.com/matsumotory/items/4ec902f2977b91eba427)
- [mruby-mysql 作った。](http://mattn.kaoriya.net/software/lang/ruby/20130120012259.htm)
