---
author: "Takuma Kume"
title: "httpd + mod_mrubyでプログラマブルなWEBサーバを構築する"
linktitle: "httpd + mod_mrubyでプログラマブルなWEBサーバを構築する"
date: 2016-07-26T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "mod_mruby"]
---

### はじめに

こんばんは。GMOペパボの久米です。
以前、「[CentOS6で ngx_mruby + mruby-memcached + mruby-mysql をインストールした。](/blog/2016-04-11-try-install-ngx-mruby/)」という記事でプログラマブルに制御できるnginxの紹介をし、リバースプロキシの構築を行いました。

本エントリでは、同様にプログラマブルに制御できるWEBサーバとしてApacheに [@matsumotory](https://twitter.com/matsumotory)さん が作成している、 [mod_mruby](https://github.com/matsumoto-r/mod_mruby) というモジュールを組み込みたいと思います。

これにより、[ngx_mruby](https://github.com/matsumoto-r/ngx_mruby) 同様にmrubyを使って動的にWEBサーバの設定を変更することができます。

### 環境

|#|バージョン|
|---|---|
|OS|CentOS 6.6|
|httpd|2.2.15-54|
|ruby|1.9.3|

### 必要なコンポーネント、ライブラリをインストール

```sh
yum install -y httpd httpd-devel php git zlib zlib-devel pcre-devel bison openssl-devel readline-devel
```

### Ruby(rbenv環境)をインストール

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

#### rubyのバージョンを選択

- 今回は1.9.xの最新版を利用する。

```sh
rbenv install --list
rbenv install 1.9.3-p551
rbenv global 1.9.3-p551
```

### mod_mrubyのビルドに必要なrakeをインストール

```sh
rbenv exec gem install rake
```

### mod_mrubyをビルド

#### ソースをダウンロード

```sh
cd /usr/local/src
git clone https://github.com/matsumoto-r/mod_mruby.git
```

#### ビルド

```sh
cd mod_mruby
sh ./test.sh
sh ./build.sh
```

### httpdにmod_mrubyを組み込む

```sh
cp -p /usr/local/src/mod_mruby/src/.libs/mod_mruby.so /etc/httpd/modules/
vi /etc/httpd/conf.d/mruby.conf
```

##### mruby.conf

```sh
LoadModule mruby_module modules/mod_mruby.so
<Location /mruby-test>
    mrubyHandlerMiddle /etc/httpd/lib/test.rb
</Location>
```

### 動作確認

```sh
mkdir /etc/httpd/lib
cp -p /usr/local/src/mod_mruby/test/test.rb /etc/httpd/lib/
service httpd start
curl http://127.0.0.1/mruby-test
```

##### 実行結果

```sh
(snip)
__Test Complete. Wellcome to mod_mruby world!!__
```


はろーーーmod_mruby!!!
