---
author: "Takuma Kume"
title: "ngx_mrubyでmemcachedやmysqldのコネクションを使いまわす(性能測定)"
linktitle: "ngx_mrubyでmemcachedやmysqldのコネクションを使いまわす(性能測定)"
date: 2016-07-15T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "ngx_mruby"]
---

### はじめに

どうも、GMOペパボ 久米です。
そろそろ（最初から）雇用形態の話は面白くないので、これからのはじめの挨拶は何にしようか悩んでいます。

さて、今回は以下で作った[ngx_mruby](https://github.com/matsumoto-r/ngx_mruby)の性能の検証をしようと思います。
[ngx_mrubyでmemcachedやmysqldのコネクションを使いまわす](/blog/2016-07-14-connection-recycle/)

### 性能検証の目的

ngx_mrubyからリクエスト毎にmemcachedに接続する場合と、[mruby-userdata](https://github.com/matsumoto-r/mruby-userdata)でコネクションを使い回す場合とでどの程度の性能差が出るのかを確認したい。

### 前提

- 実行環境: MacBook Pro (Retina 13-inch、Early 2015)
  - CPU 2.7 GHz Intel Core i5
  - RAM 16 GB 1867 MHz DDR3
  - Virtual Box上の仮想マシン

- 今回は測定結果の値そのものではなく、それぞれの性能差を比較する。

### 測定方法

- 静的コンテンツ
- Apache Benchmarkを利用
- とりあえず 100多重　１０万アクセス

### 検証コード

##### mruby_get_proxypass.rb　（毎回接続するパターン）

```ruby
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

# memcacheに接続する。
Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: trying to connect to memcached. host=" + memecached_server
memcached = Memcached.new memecached_server

# request domainからホストされているサーバを照会する。
Nginx.return -> do

    # memcachedからproxy_passを取得するし格納する。
    proxy_pass = memcached.get v.http_host

    # memcachedからproxy_passが取得できた場合は処理を抜ける。
    if proxy_pass != nil then
        Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: memcached: req=" + v.http_host + " res=" + proxy_pass
        return Nginx::DECLINED
    end

    # mysqldに接続する。
    Nginx.errlogger Nginx::LOG_INFO, "mruby_get_proxypass: trying to connect to mysqld. host=" + mysqld_server
    mysqld = MySQL::Database.new(mysqld_server, mysqld_user, mysqld_password, mysqld_database)

    # mysqldからproxy_passを取得する。
    mysql_result = mysqld.execute("SELECT host FROM domain WHERE domain = ? LIMIT 1", "#{v.http_host}")

    # mysqldから結果が帰ってくればproxy_passに格納する。
    if mysql_result != nil then
        proxy_pass = mysql_result.next[0]
        mysql_result.close
    end

    mysqld.close

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

memcached.close

proxy_pass
```

##### mruby_get_proxypass.rb (コネクションを使い回すパターン)

```ruby
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

### 結果

##### 毎回接続するパターン

```
[root@web2 ~]# ab -c 100 -n 100000 -k http://site-a.local/
This is ApacheBench, Version 2.3 <$Revision: 655654 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking site-a.local (be patient)
Completed 10000 requests
Completed 20000 requests
Completed 30000 requests
Completed 40000 requests
Completed 50000 requests
Completed 60000 requests
Completed 70000 requests
Completed 80000 requests
Completed 90000 requests
Completed 100000 requests
Finished 100000 requests


Server Software:        nginx/1.9.14
Server Hostname:        site-a.local
Server Port:            80

Document Path:          /
Document Length:        13 bytes

Concurrency Level:      100
Time taken for tests:   276.751 seconds
Complete requests:      100000
Failed requests:        0
Write errors:           0
Keep-Alive requests:    99050
Total transferred:      27395250 bytes
HTML transferred:       1300000 bytes
Requests per second:    361.34 [#/sec] (mean)
Time per request:       276.751 [ms] (mean)
Time per request:       2.768 [ms] (mean, across all concurrent requests)
Transfer rate:          96.67 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.4      0      14
Processing:    24  277 116.1    263    6233
Waiting:       10  276 116.1    263    6233
Total:         25  277 116.1    263    6234

Percentage of the requests served within a certain time (ms)
  50%    263
  66%    276
  75%    286
  80%    295
  90%    336
  95%    384
  98%    467
  99%    591
 100%   6234 (longest request)
```

```sh
netstat -tanp | grep 192.168.100.10 |wc -l
8017
```

リクエスト毎にmemcachedに接続するため、ディスコネクトが追いつかずに溜まっていく。

##### コネクションを使い回すパターン

```
[root@client ~]# ab -c 100 -n 100000 -k http://site-a.local/
This is ApacheBench, Version 2.3 <$Revision: 655654 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking site-a.local (be patient)
Completed 10000 requests
Completed 20000 requests
Completed 30000 requests
Completed 40000 requests
Completed 50000 requests
Completed 60000 requests
Completed 70000 requests
Completed 80000 requests
Completed 90000 requests
Completed 100000 requests
Finished 100000 requests


Server Software:        nginx/1.9.14
Server Hostname:        site-a.local
Server Port:            80

Document Path:          /
Document Length:        13 bytes

Concurrency Level:      100
Time taken for tests:   190.936 seconds
Complete requests:      100000
Failed requests:        0
Write errors:           0
Keep-Alive requests:    99047
Total transferred:      27395235 bytes
HTML transferred:       1300000 bytes
Requests per second:    523.74 [#/sec] (mean)
Time per request:       190.936 [ms] (mean)
Time per request:       1.909 [ms] (mean, across all concurrent requests)
Transfer rate:          140.12 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.5      0      16
Processing:    18  191  74.7    185    4607
Waiting:        2  191  74.7    185    4607
Total:         20  191  74.8    185    4607

Percentage of the requests served within a certain time (ms)
  50%    185
  66%    193
  75%    200
  80%    205
  90%    223
  95%    242
  98%    275
  99%    342
 100%   4607 (longest request)
```

### 比較

- Request/sec
  - 毎回接続  361.34
  - 接続を使い回す 523.74

### 結論

mruby-userdataを用いて接続を使い回すと、毎回接続するときに比べて **1.45倍** 程度性能が向上した！

### 訂正

接続を使い回した場合のab結果見間違えてまして、修正しました。　2016/07/15 11:12
