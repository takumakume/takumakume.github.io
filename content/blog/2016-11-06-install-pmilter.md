---
author: "Takuma Kume"
title: "pmilter + postfixでプログラマブルなSMTPサーバを作る（入門編）"
linktitle: "pmilter + postfixでプログラマブルなSMTPサーバを作る（入門編）"
date: 2016-11-06T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "pmilter"]
---

## pmilterとは

- [pmilter](https://github.com/matsumotory/pmilter)
- [@matsumotory](https://twitter.com/matsumotory)が開発している[mruby](https://github.com/mruby/mruby)でコントロール可能な[milter](https://en.wikipedia.org/wiki/Milter)である。
- ngx_mrubyやmod_mrubyなどを使ったことがある人であれば、そのようなイメージでメールの制御を行うことができる。

##### 何ができるのか？

- MTAに組み込むことで、メールの様々な情報を元にmrubyで制御できる。
  - SMTPプロトコルの各フェーズでmrubyをフックすることができ、メールのenvelopeやヘッダ、TLSの情報や認証情報などを利用してメールの制御を行うことができる。

## 環境を構築する

##### 環境

- CentOS 7.2
- postfix 8.14.7
- ruby 2.0

##### SELinuxの無効化

- SELinuxを無効にしないと、pmilterのsocketとpostfixが通信できなくなる。

```sh
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
setenforce 0
```

##### 必要なパッケージのインストール

```sh
yum install -y git \
               mailx \
               ruby \
               gcc \
               gcc-c++ \
               make \
               cmake \
               autoconf \
               automake \
               libtool \
               bison
rpm -ivh ftp://ftp.pbone.net/mirror/ftp.sourceforge.net/pub/sourceforge/k/ke/kenzy/special/C7/x86_64/ragel-6.8-3.el7.centos.x86_64.rpm
```

##### pmilterのビルド

```sh
cd /usr/local/src/ && git clone https://github.com/matsumoto-r/pmilter.git
```

```sh
cd /usr/local/src/pmilter
make mruby
make
```

```sh
[root@pmilter pmilter]# file pmilter
pmilter: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), dynamically linked (uses shared libs), for GNU/Linux 2.6.32, BuildID[sha1]=5bed3d8ff85db4e11865d073542d063671c61794, not stripped
```

##### pmilterの設定

今回はSMTPサーバにpmilterを同居させて、socketを使ってpostfixと通信する。

- pmilter.conf の listen を以下のようにする。

```sh
listen = "/var/spool/postfix/pmilter/pmilter.sock"
```

- ディレクトリを作成

```sh
mkdir -p /var/spool/postfix/pmilter
```

##### pmilterを起動する

- 以下のようにするとフォアグラウンドでpmilterが起動する。
- 実際にはpostfixの起動スクリプトなどにバックグラウンドで起動するようにする感じ。

```sh
sudo -u postfix ./pmilter -c pmilter.conf
[Thu, 03 Nov 2016 15:38:11 GMT][notice]: pmilter/0.0.1 starting

```

##### postfix で pmilter の socket を利用する。

- /etc/postfix/main.cf に以下を記述する。

```sh
smtpd_milters = unix:/var/spool/postfix/pmilter/pmilter.sock
```

- postfix を再起動する。

```sh
systemctl restart postfix
```

##### 動作確認

- メールを送信

```sh
echo "test" | mail -s "test" YOUR_MAILADDRESS@gmail.com
```

- デフォルトであれば、SMTPプロトコルの各フェーズで取得できる情報が表示される。

```
# sudo -u postfix ./pmilter -c pmilter.conf
[Thu, 03 Nov 2016 15:38:11 GMT][notice]: pmilter/0.0.1 starting
ello pmilter handler called from pmilter
client ipaddr 127.0.0.1
client hostname pmilter.local
client daemon pmilter.local
handler phase name: mruby_connect_handler
helo hostname: pmilter.local
tls client issuer:
tls client subject:
tls session key size:
tls encrypt method:
tls version:
env from from args: <vagrant@pmilter.local>
env from from symval: vagrant@pmilter.local
SASL login name:
SASL login sender: vagrant@pmilter.local
SASL login type:
env to from arg: YOUR_MAILADDRESS@gmail.com
env to from symval: YOUR_MAILADDRESS@gmail.com
header: {"Received"=>"(from root@localhost)\n\tby pmilter.local (8.14.7/8.14.7/Submit) id uA49fLxF003015\n\tfor YOUR_MAILADDRESS@gmail.com; Fri, 4 Nov 2016 09:41:21 GMT"}
header: {"From"=>"vagrant <vagrant@pmilter.local>"}
header: {"Message-Id"=>"<201611040941.uA49fLxF003015@pmilter.local>"}
header: {"Date"=>"Fri, 04 Nov 2016 09:41:21 +0000"}
header: {"To"=>"YOUR_MAILADDRESS@gmail.com"}
header: {"Subject"=>"test"}
header: {"User-Agent"=>"Heirloom mailx 12.5 7/5/10"}
header: {"MIME-Version"=>"1.0"}
header: {"Content-Type"=>"text/plain; charset=us-ascii"}
header: {"Content-Transfer-Encoding"=>"7bit"}
body chunk; test
myhostname: pmilter.local
message_id: B6D5080AD79D
reveive_time: Fri Nov 04 09:41:21 2016
add_header(X-Pmilter:True): Enable
hello pmilter handler called from pmilter
client ipaddr 127.0.0.1
client hostname pmilter.local
client daemon pmilter.local
handler phase name: mruby_connect_handler
helo hostname: pmilter.local
tls client issuer:
tls client subject:
tls session key size:
tls encrypt method:
tls version:
env from from args: <vagrant@pmilter.local>
env from from symval: vagrant@pmilter.local
SASL login name:
SASL login sender: vagrant@pmilter.local
SASL login type:
env to from arg: YOUR_MAILADDRESS@gmail.com
env to from symval: YOUR_MAILADDRESS@gmail.com
header: {"Received"=>"(from root@localhost)\n\tby pmilter.local (8.14.7/8.14.7/Submit) id uA49gxKT003138\n\tfor YOUR_MAILADDRESS@gmail.com; Fri, 4 Nov 2016 09:42:59 GMT"}
header: {"From"=>"vagrant <vagrant@pmilter.local>"}
header: {"Message-Id"=>"<201611040942.uA49gxKT003138@pmilter.local>"}
header: {"Date"=>"Fri, 04 Nov 2016 09:42:59 +0000"}
header: {"To"=>"YOUR_MAILADDRESS@gmail.com"}
header: {"Subject"=>"test"}
header: {"User-Agent"=>"Heirloom mailx 12.5 7/5/10"}
header: {"MIME-Version"=>"1.0"}
header: {"Content-Type"=>"text/plain; charset=us-ascii"}
header: {"Content-Transfer-Encoding"=>"7bit"}
body chunk; test
myhostname: pmilter.local
message_id: 34B2780AD79D
reveive_time: Fri Nov 04 09:42:59 2016
add_header(X-Pmilter:True): Enable
```

- 次回はこれらの情報からメールを制御してみる。
