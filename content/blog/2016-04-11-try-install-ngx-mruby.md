---
author: "Takuma Kume"
title: "CentOS6で ngx_mruby + mruby-memcached + mruby-mysql をインストールした"
linktitle: "CentOS6で ngx_mruby + mruby-memcached + mruby-mysql をインストールした"
date: 2016-04-11T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "ngx_mruby"]
---

こんばんは。GMOペパボ試用期間の久米です。

以下の要件のリバースプロキシサーバを作成したいため、[ngx_mruby](https://github.com/matsumoto-r/ngx_mruby)を触ってみました。

- リクエストホスト名に応じて転送先のサーバを変更する。
- ホスト名と転送先サーバのひも付けの情報をMemcachedのサーバから取得する。
- キャッシュが存在していなければMySQLデータベースから取得し、キャッシュを書き込む。

この要件を [ngx_mruby](https://github.com/matsumoto-r/ngx_mruby) + [mruby-memcached](https://github.com/matsumoto-r/mruby-memcached) + [mruby-mysql](https://github.com/mattn/mruby-mysql) で満たすべく、
本エントリではインストール方法について記載します。

#### 環境

|#|バージョン|
|---|---|
|OS|CentOS 6.6|
|kernel|2.6.32-504.el6.x86_64|
|Ruby|2.2.4|
|nginx|1.9.14|
|ngx_mruby|1.1.17|

#### 今回はルートユーザで作業を行います。

```sh
sudo su -
```

### Ruby (rbenv) 環境を構築

#### 必要なライブラリをインストール

```sh
yum install -y git openssl-devel readline-devel zlib-devel
```

#### rbenv + ruby-buildをダウンロード

```sh
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
```

#### rbenvのPATHの設定

```sh
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bash_profile
echo 'eval "$(rbenv init -)"' >> ~/.bash_profile
exec $SHELL -l
```

#### Rubyをインストール

- インストールできるRubyのバージョンを確認
- 今回は"2.2.4"をチョイス

```sh
rbenv install --list
 :
2.2.3
2.2.4
2.3.0-dev
2.3.0-preview1
2.3.0-preview2
2.3.0
2.4.0-dev
 :
```

- rbenvでRubyをインストールする。

```sh
rbenv install 2.2.4
rbenv global 2.2.4
```

- バージョン確認

```sh
rbenv versions
* 2.2.4 (set by /root/.rbenv/version)
```

#### serverspecをインストール

```sh
rbenv exec gem install serverspec
```

### ngx_mruby + mruby_memecached + mruby_mysql をインストール

#### 必要なライブラリのインストールとソースのダウンロード

- mruby-memcachedに必要なライブラリ

```sh
yum install -y pcre-devel bison
rpm --import http://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-6
rpm -ivh http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm
rpm --import http://rpms.famillecollet.com/RPM-GPG-KEY-remi
rpm -ivh http://rpms.famillecollet.com/enterprise/remi-release-6.rpm
yum -y install --enablerepo=remi libmemcached-last-devel
```

- mruby-mysqlに必要なライブラリ

```sh
yum install -y mysql mysql-devel
```

- nginx, ngx_mrubyのソースをダウンロード

```sh
mkdir /usr/local/src/nginx && cd /usr/local/src/nginx
git clone https://github.com/matsumoto-r/ngx_mruby.git
curl -O http://nginx.org/download/nginx-1.9.14.tar.gz
tar zxf nginx-1.9.14.tar.gz
```

#### ビルド

以下を参考にして、ビルドしました。
[matsumoto-r/ngx_mruby Wiki Install](https://github.com/matsumoto-r/ngx_mruby/wiki/Install)

- ngx_mubyは "build_config.rb" で利用するモジュールを選択してビルドする仕組みです。

```sh
cd ngx_mruby && vi build_config.rb
```

- 以下のモジュールもビルドするようにコメントアウトを外します。
  - mruby-memcached
  - mruby-mysql

```sh
 :
conf.gem :github => 'matsumoto-r/mruby-memcached'
 :
conf.gem :github => 'mattn/mruby-mysql'
 :
```

- プレフィックスとnginxのソース配置先を環境変数に設定して build.sh を実行します。

```sh
NGINX_CONFIG_OPT_ENV='--prefix=/usr/local/nginx' NGINX_SRC_ENV='/usr/local/src/nginx/nginx-1.9.14/' sh build.sh
 :
ngx_mruby building ... Done
build.sh ... successful
```

- インストール

```sh
make install
```

- 動作確認用の記述を nginx.conf に設定します。

```sh
vi /usr/local/nginx/conf/nginx.conf
```

- location /mruby .. を設定

```sh
 :
http {
   :
  server {
     :
    location /mruby {
      mruby_content_handler '/usr/local/nginx/html/unified_hello.rb';
    }
     :
  }
   :
}
 :
```

- スクリプトを配置

```sh
vi /usr/local/nginx/html/unified_hello.rb
```

```sh
if server_name == "NGINX"
  Server = Nginx
elsif server_name == "Apache"
  Server = Apache
end

Server::rputs "Hello #{Server::module_name}/#{Server::module_version} world!"
```

### 起動の設定

- initスクリプトを作成します

```sh
vi /etc/init.d/nginx
```

- 以下のURLからコピーしてきます

> Red Hat NGINX Init Script
> https://www.nginx.com/resources/wiki/start/topics/examples/redhatnginxinit/

- 環境に合わせてパスを修正します

```sh
 :
#nginx="/usr/sbin/nginx"
nginx="/usr/local/nginx/sbin/nginx"
 :
#NGINX_CONF_FILE="/etc/nginx/nginx.conf"
NGINX_CONF_FILE="/usr/local/nginx/conf/nginx.conf"
 :
```

- 起動スクリプトの設定

```sh
chmod +x /etc/init.d/nginx
chkconfig --add nginx
chkconfig nginx on
```

- 起動してみる

```sh
service nginx start
```

- 動作確認

```sh
curl http://127.0.0.1/mruby
```

Hello ngx_mruby/1.17.0 world!


はろーー！ngx_mruby！！
