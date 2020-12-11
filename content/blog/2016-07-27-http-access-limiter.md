---
author: "Takuma Kume"
title: "mod_mruby + http-access-limiterでファイル単位での同時アクセス数を制御し性能比較をした"
linktitle: "mod_mruby + http-access-limiterでファイル単位での同時アクセス数を制御し性能比較をした"
date: 2016-07-27T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "mod_mruby"]
---

### はじめに

こんばんは、GMOペパボの久米です。

「[httpd + mod_mrubyでプログラマブルなWEBサーバを構築する](/blog/2016-07-26-install-mod-mruby/)」というエントリを書きましたが、今回は [mod_mruby](https://github.com/matsumoto-r/mod_mruby) を使った、 [@matsumotory](https://twitter.com/matsumotory)さん が作成している [http-access-limiter](https://github.com/matsumoto-r/http-access-limiter) というリクエスト先ファイル単位での同時アクセス数を制御できるソフトウェアの導入と検証を行います。

レンタルサーバなど複数のドメインを収容している場合など、サーバの管理者が実行されるプログラムを制御出来ない、あるいはリクエスト数を想定できない時に以下のような運用課題が発生する。

- サーバに収容している特定のドメインに大量にアクセスが発生し過負荷状態になる。
  - これは [matsumoto-r/mod_vhost_maxclients](https://github.com/matsumoto-r/mod_vhost_maxclients) を利用することで解決する。
  - しかし、リクエスト先ドメイン単位での同時アクセス数を制限するため負荷にほとんど影響しないファイルまで含めて制御対象となる。
- サーバに収容している特定のプログラムが重い処理を実行され過負荷状態になる。

本エントリでは [mod_mruby](https://github.com/matsumoto-r/mod_mruby) + [http-access-limiter](https://github.com/matsumoto-r/http-access-limiter) でそれらを解決するための導入検証及び性能比較を行います。

### 前提

[httpd + mod_mrubyでプログラマブルなWEBサーバを構築する](/blog/2016-07-26-install-mod-mruby/) で構築した環境を利用する。

### 導入

```sh
git clone https://github.com/matsumoto-r/http-access-limiter.git
cd http-access-limiter
cp -pi access_limiter_apache.conf /etc/httpd/conf.d/
cp -pri access_limiter /etc/httpd/conf.d/
```

導入は以上。とても簡単ですね！

##### /etc/httpd/conf.d/access_limiter_apache.conf

```sh
<IfModule mod_mruby.c>
  mrubyPostConfigMiddle         /etc/httpd/conf.d/access_limiter/access_limiter_init.rb cache
  mrubyChildInitMiddle          /etc/httpd/conf.d/access_limiter/access_limiter_worker_init.rb cache
  <FilesMatch ^.*\.php$>
    mrubyAccessCheckerMiddle      /etc/httpd/conf.d/access_limiter/access_limiter.rb cache
    mrubyLogTransactionMiddle     /etc/httpd/conf.d/access_limiter/access_limiter_end.rb cache
  </FilesMatch>
</IfModule>
```

**"FilesMatch ^.*\.php$"** の部分で制御対象のファイルを指定します。
上記ではすべての　php ファイルが指定されています。

##### /etc/httpd/conf.d/access_limiter/access_limiter.rb

```sh
####
threshold = 2
####
(snip)
```

上記を編集して、許容する同時アクセス数を指定します。

##### httpdをrestartします。

```sh
/etc/init.d/httpd configtest && /etc/init.d/httpd restart
```

### 以下のコードをDocumentRootに配置して動作確認

##### sleep.php

```php
<?php
sleep(3);
echo "loaded";
?>
```

ブラウザから３つアクセスを行う。

```html
1つ目： loaded
2つ目： loaded
3つ目： Service Temporarily Unavailable
```

error_log

```
[Tue Jul 27 00:48:42 2016] [notice] access_limiter: file:/var/www/html/sleep.php counter:1
[Tue Jul 27 00:48:42 2016] [notice] access_limiter: file:/var/www/html/sleep.php counter:2
[Tue Jul 27 00:48:42 2016] [notice] access_limiter: file:/var/www/html/sleep.php counter:3
[Tue Jul 27 00:48:42 2016] [notice] access_limiter: file:/var/www/html/sleep.php reached threshold: 2: return 503
```

正常にアクセスを制御できていることが分かる。

### 性能を比較

http-access-limiterを利用することでどの程度パフォーマンスに影響するかを確認したい。
以下の性能差を確認する。

- http-access-limiterを利用しない。
- http-access-limiterを有効にして実質アクセス制限にかからないようなしきい値に設定しておく。
- http-access-limiterを有効にして実質アクセス制限にかからないようなしきい値に設定し、キャッシュオプションを無効にする。

#### 環境

前回の性能測定時は１CPUの仮想マシンでサーバ側とクライアント側を実装していた。
[@matsumotory](https://twitter.com/matsumotory)さんに仮想マシンが１つのCPUを掴もうとして競合して処理待ちが発生すると測定値の精度が落ちる場合があるとご指摘いただきましたので今回は仮想マシンの性能を上げてます。

- ホスト: MacBook Pro (Retina 13-inch、Early 2015) 2.7 GHz Intel Core i5
- 仮想マシン
  - サーバ (httpd + mod_mruby + http-access-limtter)
      - CPU * 2
      - RAM 2GB
  - クライアント (ab)
      - CPU * 2
      - RAM 2GB

#### サーバ側の実装

##### /etc/httpd/conf.d/access_limiter_apache.conf

```sh
<IfModule mod_mruby.c>
  mrubyPostConfigMiddle         /etc/httpd/conf.d/access_limiter/access_limiter_init.rb cache
  mrubyChildInitMiddle          /etc/httpd/conf.d/access_limiter/access_limiter_worker_init.rb cache
  <FilesMatch ^.*\.php$>
    mrubyAccessCheckerMiddle      /etc/httpd/conf.d/access_limiter/access_limiter.rb cache
    mrubyLogTransactionMiddle     /etc/httpd/conf.d/access_limiter/access_limiter_end.rb cache
  </FilesMatch>
</IfModule>
```

##### /etc/httpd/conf.d/access_limiter/access_limiter.rb

```sh
####
threshold = 90000000
####
```

とりあえず9千万に設定。

##### アクセス先ファイル: /var/www/html/test.php

```php
<?php
phpinfo();
?>
```

#### 【測定結果】http-access-limiterを利用しない。

```
# ab -c 100 -n 100000 -k http://192.168.100.51/test.php
This is ApacheBench, Version 2.3 <$Revision: 655654 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking 192.168.100.51 (be patient)
Completed 10000 requests
:
Finished 100000 requests


Server Software:        Apache/2.2.15
Server Hostname:        192.168.100.51
Server Port:            80

Document Path:          /test.php
Document Length:        51635 bytes

Concurrency Level:      100
Time taken for tests:   279.473 seconds
Complete requests:      100000
Failed requests:        0
Write errors:           0
Keep-Alive requests:    0
Total transferred:      5181044073 bytes
HTML transferred:       5163842353 bytes
Requests per second:    357.82 [#/sec] (mean)
Time per request:       279.473 [ms] (mean)
Time per request:       2.795 [ms] (mean, across all concurrent requests)
Transfer rate:          18104.11 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0   18  52.6     12    1917
Processing:     2  261 487.5    140   28597
Waiting:        0   68 166.3     31    7075
Total:          2  279 490.3    157   28601
```

#### 【測定結果】http-access-limiterを有効にして実質アクセス制限にかからないようなしきい値に設定しておく。

```sh
tail -f  /var/log/httpd/error_log | grep 503
```

測定中にhttp-access-limiterに引っかかってしまうならば、しきい値を調整しなければならないためモニタリングしておく。

```
# ab -c 100 -n 100000 -k http://192.168.100.51/test.php
This is ApacheBench, Version 2.3 <$Revision: 655654 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking 192.168.100.51 (be patient)
Completed 10000 requests
:
Finished 100000 requests


Server Software:        Apache/2.2.15
Server Hostname:        192.168.100.51
Server Port:            80

Document Path:          /test.php
Document Length:        51645 bytes

Concurrency Level:      100
Time taken for tests:   287.744 seconds
Complete requests:      100000
Failed requests:        0
Write errors:           0
Keep-Alive requests:    0
Total transferred:      5183134910 bytes
HTML transferred:       5165926310 bytes
Requests per second:    347.53 [#/sec] (mean)
Time per request:       287.744 [ms] (mean)
Time per request:       2.877 [ms] (mean, across all concurrent requests)
Transfer rate:          17590.82 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0   12  38.7      5    1104
Processing:     2  275 462.1    158   14122
Waiting:        0   90 207.1     36    4645
Total:          2  287 464.5    170   14127

Percentage of the requests served within a certain time (ms)
  50%    170
  66%    224
  75%    276
  80%    323
  90%    538
  95%    999
  98%   1606
  99%   2014
 100%  14127 (longest request)
```

##### 【測定結果】http-access-limiterを有効にして実質アクセス制限にかからないようなしきい値に設定しておく。キャッシュオプションを無効にする。

- cacheオプションを外すことで、mrubyスクリプトが毎回コンパイルされる。代わりに内容が変更されてもhttpdのリロードが不要。
- 本検証はhttpdのgracefulなしにしきい値を変更する場合を考えてどの程度パフォーマンスが低下するかを確認したい。

```diff
-    mrubyAccessCheckerMiddle      /etc/httpd/conf.d/access_limiter/access_limiter.rb cache
+    mrubyAccessCheckerMiddle      /etc/httpd/conf.d/access_limiter/access_limiter.rb
```

```
root@client vagrant]# ab -c 100 -n 100000 -k http://192.168.100.51/test.php
This is ApacheBench, Version 2.3 <$Revision: 655654 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking 192.168.100.51 (be patient)
Completed 10000 requests
:
Finished 100000 requests


Server Software:        Apache/2.2.15
Server Hostname:        192.168.100.51
Server Port:            80

Document Path:          /test.php
Document Length:        51645 bytes

Concurrency Level:      100
Time taken for tests:   301.550 seconds
Complete requests:      100000
Failed requests:        0
Write errors:           0
Keep-Alive requests:    0
Total transferred:      5182168550 bytes
HTML transferred:       5164965454 bytes
Requests per second:    331.62 [#/sec] (mean)
Time per request:       301.550 [ms] (mean)
Time per request:       3.016 [ms] (mean, across all concurrent requests)
Transfer rate:          16782.33 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    9  28.3      3    1303
Processing:     2  291 410.5    186   12616
Waiting:        0   94 192.1     41    7384
Total:          3  300 412.5    195   12651

Percentage of the requests served within a certain time (ms)
  50%    195
  66%    262
  75%    326
  80%    375
  90%    559
  95%    906
  98%   1563
  99%   2024
 100%  12651 (longest request)
```

### 性能差を比較

| 項目                                | Rec/sec |
| :--                                | ---     |
| http-access-limiter：無効            | 357.82 |
| http-access-limiter：有効            | 347.53 |
| http-access-limiter：有効（no cache)  | 331.62 |

- http-access-limiterを有効にした時にどの程度のパフォーマンス低下が発生するか。
  - Requests per secondは約2.9％低下する。

- http-access-limiterのcacheオプションを無効にした場合にどの程度パフォーマンスが低下するか。
  - Requests per secondは約4.5%低下する。

### 総括

http-access-limiterで思ったよりパフォーマンスの劣化は見られなかった。
時間的に実施できていないが、想定よりも性能劣化が発生しない印象なので差を広げる意味でも100万リクエストくらい処理させた場合の性能差も測定したい。
後は、cacheオプションを外した時にコンパイル処理がどの程度メモリを消費するかなども見る必要があるとご指摘も頂いているので後日の課題としたい。
更にはhttp-access-limiterを運用に乗せる場合などを考慮し、より設定を管理しやすくするにはどうすればよいかなどの考察も行っていく必要があると考える。
