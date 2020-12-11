---
author: "Takuma Kume"
title: "pmilterでmrubyを用いてメールのDDoSを軽減する"
linktitle: "pmilterでmrubyを用いてメールのDDoSを軽減する"
date: 2016-12-13T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "pmilter", "advent_calendar"]
---

この記事は [mruby Advent Calendar 2016](http://qiita.com/advent-calendar/2016/mruby) の13日目の記事です。

本エントリでは [matsumotory](https://twitter.com/matsumotory) さんが作成された、mrubyでメールの制御を行うことができる [pmilter](https://github.com/matsumotory/pmilter) を使ってSMTPのDDoSを軽減するソフトウェアを作ってみたのでその紹介をします。

## pmilterとは？

pmilterはProgrammable Mail Filterの略で、SMTPサーバ（送信や受信）とmilterプロトコルで通信し、SMTPサーバの送受信の振る舞いをRubyでコントロールできるサーバソフトウェアです。

インストールや設定はシンプルでpmilterのバイナリを配置して通常のmilterのようにSMTPサーバに設定するだけです。

```
### postfixの設定
smtpd_milters = unix:/pmilter/pmilter.sock
```

そして、milterプロトコルの各フェーズで任意のmrubyスクリプトをフックします。

```
### pmilterの設定

 : (snip)
[handler]
# connection info filter handler
mruby_connect_handler = "handler/connect.rb"

# SMTP HELO command filter handler
mruby_helo_handler = "handler/helo.rb"
 : (snip)
```

[ngx_mruby](https://github.com/matsumotory/ngx_mruby)や[mod_mruby](https://github.com/matsumotory/mod_mruby)を利用したことのある方ならよりイメージしやすいと思います。

詳しくは以下をご参照ください。

- [Pmilter: Programmable Mail Filter Serverを作った](http://hb.matsumoto-r.jp/entry/2016/11/03/121517)

## pmilterのセットアップ

筆者はCentOS7で動作確認を行いました。セットアップについては以下のエントリをご参照ください。

- [pmilter + postfixでプログラマブルなSMTPサーバを作る（入門編）](/blog/2016-11-06-install-pmilter/)

## pmilterでメールのDDoSを軽減する

##### smtp-dos-detector

今回、[takumakume/smtp-dos-detector](https://github.com/takumakume/smtp-dos-detector) というソフトウェアを作りました。
これは、一定間隔にSMTP接続できる回数を制限したり、送信できるメール通数を制御したりできます。

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

##### smtp-dos-detectorの使い方

今回は、IPアドレス単位で一定間隔にSMTP接続をできる回数を制限してみます。

- pmilter.conf に以下のように設定する。

```
[handler]
# connection info filter hhandler/connect.rb"
mruby_connect_handler = "handler/smtp-dos-detector/src/smtp_dos_detector.rb"
```

- handler/smtp-dos-detector/src/smtp_dos_detector.rb のように [smtp-dos-detector](https://github.com/takumakume/smtp-dos-detector) のmruby scriptを配置します。以下のようになっていると思います。

```ruby
: (snip)

target = Pmilter::Session.new.client_ipaddr

config = {
  :counter_key       => target,
  :threshold_time    => 10,
  :threshold_counter => 5,
  :expire_time       => 30,
  :behind_counter    => -10,
}

timeout = global_mutex.try_lock_loop(50000) do
  dos = DosDetector.new config
  data = dos.analyze
  p "smtp-dos-detector: analyze: #{data}"
  begin
    if dos.detect?
      p "smtp-dos-detector: detect: #{data}"
      Pmilter.status = Pmilter::SMFIS_REJECT
    end
  rescue => e
    raise "smtp-dos-detector: fail: #{e}"
  ensure
    global_mutex.unlock
  end
end
p "smtp-dos-detector: get timeout mutex lock, #{data}" if timeout
```

- 以下に、更に詳しい説明をしていきます。

```ruby
target = Pmilter::Session.new.client_ipaddr
```

これは、pmilterからSMTP接続を行ったクライアントのIPアドレスを取得しています。
今回は、IPアドレス単位で一定間隔にSMTP接続をできる回数を制限するためです。

```ruby
config = {
  :counter_key       => target,
  :threshold_time    => 10,
  :threshold_counter => 5,
  :expire_time       => 30,
  :behind_counter    => -10,
}
```

:counter_key には、pmilterから取得したsmtp接続をしてきたクライアントのIPアドレスが入ります。
この設定の例では「"target"からのSMTP接続は10秒間(threshold_time)に5回(threshold_counter)まで可能で、それ以降の10回(behind_counter)の接続は30秒(expire_time)間rejectします。」となります。

```ruby
if dos.detect?
  p "smtp-dos-detector: detect: #{data}"
  Pmilter.status = Pmilter::SMFIS_REJECT
end
```

ここでは、条件にマッチしてDDoSと判定した接続に対してREJECTを返しています。

##### smtp-dos-detectorの動作

実際にメールを送信した場合にどのような挙動になるのかについて説明します。

テストのため以下のコマンドを実行してローカルからメールを送信します。

```sh
echo "test" | mail -s "test" user@hoge.local
```

メールを送信したときのpmilterの出力結果です。

```sh
# 1回目の接続：許可 (10秒以内)
"smtp-dos-detector: analyze: {:time_diff=>0, :counter=>0, :counter_key=>\"127.0.0.1\"}"
# 2回目の接続：許可 (10秒以内)
"smtp-dos-detector: analyze: {:time_diff=>2, :counter=>1, :counter_key=>\"127.0.0.1\"}"
# 3回目の接続：許可 (10秒以内)
"smtp-dos-detector: analyze: {:time_diff=>4, :counter=>2, :counter_key=>\"127.0.0.1\"}"
# 4回目の接続：許可 (10秒以内)
"smtp-dos-detector: analyze: {:time_diff=>4, :counter=>3, :counter_key=>\"127.0.0.1\"}"
# 5回目の接続：許可 (10秒以内)
"smtp-dos-detector: analyze: {:time_diff=>6, :counter=>4, :counter_key=>\"127.0.0.1\"}"
# 6回目の接続：拒否 (10秒以内)
"smtp-dos-detector: analyze: {:time_diff=>7, :counter=>5, :counter_key=>\"127.0.0.1\"}"
"smtp-dos-detector: detect: {:time_diff=>7, :counter=>5, :counter_key=>\"127.0.0.1\"}"
```

6回目の接続時にpostfixに出力されるログ

```
Dec 12 14:14:43 pmilter sendmail[5143]: uBCEEhjZ005143: to=postmaster, delay=00:00:00, xdelay=00:00:00, mailer=relay, pri=32273, relay=[127.0.0.1], dsn=5.0.0, stat=Service unavailable
```

"Service unavailable" を返している事が分かる。

```sh
# 7回目の接続：拒否 (30秒以内)
"smtp-dos-detector: analyze: {:time_diff=>0, :counter=>-9, :counter_key=>\"127.0.0.1\"}"
"smtp-dos-detector: detect: {:time_diff=>0, :counter=>-9, :counter_key=>\"127.0.0.1\"}"
  :
# 15回目の接続：拒否 (30秒以内)
"smtp-dos-detector: analyze: {:time_diff=>8, :counter=>-1, :counter_key=>\"127.0.0.1\"}"
"smtp-dos-detector: detect: {:time_diff=>8, :counter=>-1, :counter_key=>\"127.0.0.1\"}"
# 16回目の接続：許可
"smtp-dos-detector: analyze: {:time_diff=>9, :counter=>0, :counter_key=>\"127.0.0.1\"}"
# 17回目の接続：許可
"smtp-dos-detector: analyze: {:time_diff=>10, :counter=>1, :counter_key=>\"127.0.0.1\"}"
  :
  :
```

このように、大量にアクセスされた場合に適切なリターンコードでアクセスを拒否することができます。
また、smtp_dos_detector.rbのフックポイントを変えて、targetを変えることでToやFromをベースとした制御などの応用ができます。
