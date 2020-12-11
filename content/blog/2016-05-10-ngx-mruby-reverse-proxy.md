---
author: "Takuma Kume"
title: "ngx_mrubyで転送先を外部参照するリバースプロキシを構築する"
linktitle: "ngx_mrubyで転送先を外部参照するリバースプロキシを構築する"
date: 2016-05-10T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "ngx_mruby"]
---

### はじめに
どうも、GMOペパボ 試用期間の久米です。
ngx_mruby + mruby-memcached + mruby-mysql 環境構築のエントリを投稿しましたが、それを使ったリバースプロキシの構築についてまとめました。

本エントリでは以下の手順で構築したngx_mruby環境上でリバースプロキシを構築するものですので、試したい方は以下も併せてご参照ください。
[CentOS6で ngx_mruby + mruby-memcached + mruby-mysql をインストールした。](/blog/2016-04-11-try-install-ngx-mruby/)

### ngx_mrubyで転送先を外部参照するリバースWEBプロキシを構築するとは

###### 本エントリで記載する"転送先を外部参照するリバースWEBプロキシ"には以下の特徴がある。

- HTTPリクエストのホストに応じてプロキシの転送先を変更する。
- 転送先ホストの情報ソースとしてKVS(memcached)とDatabase(mysqld)を利用する。
  1. HTTPリクエストホストをKeyに転送先ホスト名をKVSに問合せる。(存在していれば修了)
  1. KVSに存在していなければ　Databaseに問合せを行う。
  1. KVSに情報を書き込む。(次回以降はキャッシュが切れるまでKVSが応答)

###### 具体的な構成と動作については以下のようになる。

<img src="/img/2016-05-10/ngx_mruby.jpg" alt="ngx_mruby-rprx.001" width="1024" height="768" class="alignnone size-medium wp-image-205" />

### Use case

- HTTPリクエストホストに応じてKVSやDatabaseの情報ソースを元にコントーロールを行いたい。
  - 例えば大量のWEBサーバに対して、ホストされているサイトをDatabaseで管理したい。
  - 高速なKVSを組合わせることで大量のリクエストを効率よく捌きたい。

通常のconfファイルで制御していたことを、ngx_mrubyを利用することでrubyスクリプトで動的に制御することができる。

### リバースプロキシの実装

リバースプロキシにはnginxを利用して、機能の実装については[ngx_mruby](https://github.com/matsumoto-r/ngx_mruby) + [mruby-memcached](https://github.com/matsumoto-r/mruby-memcached) + [mruby-mysql](https://github.com/mattn/mruby-mysql)を利用する。

###### 環境

|#|バージョン|
|---|---|
|OS|CentOS 6.6|
|kernel|2.6.32-504.el6.x86_64|
|■リバースプロキシ||
|Ruby|2.2.4|
|nginx|1.9.14|
|ngx_mruby|1.1.17|
|mruby-mysql||
|mruby-memcached||
|■KVS||
|memcached|1.4.4|
|■Database||
|mysql-server|5.1.73-5|
|■WEB||
|httpd|2.2.15|

### 検証における前提条件

- リバースプロキシとなるサーバにnginx+ngx_mruby+mruby-memcached+mruby-mysqlの環境が構築されていること。
- データーベースとなるサーバにmysqlがインストールされていること。
- 今回のテスト環境に際しては、リバースプロキシからroot権限でデータベースにアクセスできるようにgrantを通しておくこと。
- KVSとなるサーバにmemcachedがインストールされていること。
- 各サーバのiptablesは適切に設定するか無効にしておくこと。

### Let's development!!

#### 本検証に出てくるホスト名一覧

| ホスト名 | 説明 |
| --- | --- |
| proxy.local | ngx_mrubyが実装されたリバースプロキシ |
| cache.local | memcachedがインストールされたKVS |
| database.local | mysql-serverがインストールされたDBサーバ |
| web[1,2].local | httpdがインストールされた各種バーチャルホストを収容するWEBサーバ |
| site-a.local | web1.localに収容されているバーチャルサーバ |
| site-b.local | web1.localに収容されているバーチャルサーバ |
| site-c.local | web2.localに収容されているバーチャルサーバ |

#### Webサーバのバーチャルホストを設定

###### WEBサーバ共通設定

/etc/httpd/conf/httpd.conf

```
# 以下をコメントイン
NameVirtualHost *:80
```

###### web1.localの設定

/etc/httpd/conf.d/site-a.local.conf

```sh
<VirtualHost *:80>
    ServerName   site-a.local
    DocumentRoot /home/site-a.local/html
</VirtualHost>
```sh

/etc/httpd/conf.d/site-b.local.conf

```sh
<VirtualHost *:80>
    ServerName   site-b.local
    DocumentRoot /home/site-b.local/html
</VirtualHost>
```

/home/site-a.local/html/index.html

```sh
site-a.local's page
```

/home/site-b.local/html/index.html

```sh
site-b.local's page
```

###### web2.localの設定

/etc/httpd/conf.d/site-c.local.conf

```
<VirtualHost *:80>
    ServerName   site-c.local
    DocumentRoot /home/site-c.local/html
</VirtualHost>
```

/home/site-c.local/html/index.html

```
site-c.local's page
```

#### テスト用データベースの作成

```sql
create database domains default charset utf8;
use domains;
create table `domain` (
  `id` int(255) NOT NULL AUTO_INCREMENT,
  `domain` varchar(255) NOT NULL,
  `host` varchar(255) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB  DEFAULT CHARSET=utf8;
insert into domains.domain (domain, host) values ('site-a.local', 'web1.local');
insert into domains.domain (domain, host) values ('site-b.local', 'web1.local');
insert into domains.domain (domain, host) values ('site-c.local', 'web2.local');
```

#### リバースプロキシの設定

###### 今回の検証用にdnsmasqをインストール

各種サーバの名前解決のために、ローカルの"/etc/hosts"を参照してDNSクエリに応答するdnsmasqをインストールして起動しておきます。

```sh
yum install dnsmasq
chkconfig dnsmasq on
service dnsmasq start
```

以下のように名前解決ができればOK

```
# dig @localhost localhost

; <<>> DiG 9.8.2rc1-RedHat-9.8.2-0.30.rc1.el6 <<>> @localhost localhost
; (2 servers found)
;; global options: +cmd
;; Got answer:

 :

;; ANSWER SECTION:
localhost.		0	IN	A	127.0.0.1

 :
```

###### "/etc/hosts" に以下のエントリを追加しておく

```
WEBサーバ#1のIPアドレス    web1.local
WEBサーバ#2のIPアドレス    web2.local
```

###### プロキシするホストの設定

/usr/local/nginx/conf/nginx.conf
＊以下を追記

```
server {
  location / {
    resolver              127.0.0.1;
    mruby_set             $webserver "/usr/local/nginx/lib/proxy.rb";
    proxy_http_version    1.1;
    proxy_pass            http://$webserver;
    proxy_set_header      host $host;
    proxy_set_header      Connection "";
    proxy_set_header      X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header      X-Forwarded-Host $host;
    proxy_set_header      X-Forwarded-Server $host;
    proxy_set_header      X-Real-IP $remote_addr;
    proxy_send_timeout    300s;
    proxy_read_timeout    300s;
    proxy_connect_timeout 300s;
  }
}
```

###### 転送するホストをKVSやデータベースから引いたりするスクリプトを設定

/usr/local/nginx/lib/proxy.rb

```ruby
#!mruby

# memcachedの接続設定
memecached_server = "memcachedのIPアドレス:11211"

# mysqldの接続設定
mysql_server      = "mysqldのIPアドレス"
mysql_user        = "root"
mysql_password    = "PASSWORD"
mysql_database    = "domains"

# クライアントのリクエストホストを取得
request_domain = Nginx::Var.new.http_host

# memcachedから転送先ホストの情報を取得
memcached = Memcached.new memecached_server
webserver  = memcached.get request_domain

# memcachedに存在しなければmysqlに問合せる、存在していればクロージング処理へ
if webserver == nil then

  # 転送先ホストの情報を取得
  mysqld       = MySQL::Database.new(mysql_server, mysql_user, mysql_password, mysql_database)
  mysql_result = mysqld.execute("SELECT host FROM users WHERE domain = ? LIMIT 1", "#{request_domain}")

  # if recode is not found
  if mysql_result != nil then
    webserver = mysql_result.next[0]

    # mysql closing
    mysql_result.close
    mysqld.close

    # set memcached
    memcached.set request_domain, webserver
  else
    # 転送先情報が存在しない場合の処理を記載
    # エラーページを格納するサーバを記載するなど。
    # 必要に応じて、ネガティブキャッシュを実装すれば無駄なデータベース参照を減らせるかも。
  end
end

# closing memecached
memcached.close

# mruby_setにデータを渡す
webserver
```

#### 動作確認

###### クライアントの"/etc/hosts"に以下を記載する。

```
リバースプロキシのIPアドレス　　　　site-a.local site-b.local site-c.local
```

###### クライアントからアクセスしてみる

```sh
$ curl http://site-a.local
site-a.local
```

DBから値を取得して適切なサイトに転送できたことが確認できる。

###### KVSにキャッシュエントリが存在するか確認してみる

```sh
# telnet localhost 11211
Trying ::1...
Connected to localhost.
Escape character is '^]'.
get site-a.local 0 1
VALUE site-a.local 0 10
web1.local
END
```

done.
