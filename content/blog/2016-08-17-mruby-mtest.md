---
author: "Takuma Kume"
title: "mruby-mtestでngx_mrubyやmod_mrubyで使うmrubyのテストコードを書く"
linktitle: "mruby-mtestでngx_mrubyやmod_mrubyで使うmrubyのテストコードを書く"
date: 2016-08-17T00:00:00+09:00
draft: false
highlight: true
tags: ["mruby", "ci"]
---

### はじめに

こんにちは。
GMOペパボの久米です。
今回は[ngx_mruby](https://github.com/matsumoto-r/ngx_mruby)や[mod_mruby](https://github.com/matsumoto-r/mod_mruby)で動作させるmrubyスクリプトのテストコードを[iij/mruby-mtest](https://github.com/iij/mruby-mtest)を使って書いていきます。
通常この場合のmrubyスクリプトはngx_mruby/mod_mruby上で動作しますが、今回は[mruby](https://github.com/mruby/mruby)を単体でビルドして生成されたバイナリを使って動作させます。

### 環境構築

##### mrubyをgit cloneする

```sh
cd /usr/local/src
git clone https://github.com/mruby/mruby.git
cd mruby
```

##### ビルドするmgemを設定する

```sh
mv build_config.rb build_config.rb.org
vi build_config.rb
```

こちらに必要なmgemを設定します。
今回は以下のようにしました。

```ruby
MRuby::Build.new do |conf|

  toolchain :gcc

  conf.gembox 'full-core'

  conf.gem :github => 'iij/mruby-io'
  conf.gem :github => 'iij/mruby-env'
  conf.gem :github => 'iij/mruby-dir'
  conf.gem :github => 'iij/mruby-digest'
  conf.gem :github => 'iij/mruby-process'
  conf.gem :github => 'iij/mruby-pack'
  conf.gem :github => 'iij/mruby-socket'
  conf.gem :github => 'matsumoto-r/mruby-sleep'
  conf.gem :github => 'matsumoto-r/mruby-userdata'
  conf.gem :github => 'matsumoto-r/mruby-uname'
  conf.gem :github => 'matsumoto-r/mruby-mutex'
  conf.gem :github => 'matsumoto-r/mruby-cache'
  # 必要に応じてここにmgemを追記する。

  conf.gem :github => 'iij/mruby-mtest'
end
```

"conf.gem :github => 'iij/mruby-mtest'" と書いているのがテスト用のmgemです。

##### ビルドする

```sh
rake
```

##### パスの通った場所に生成されたmrubyのバイナリを配置する

```sh
cp -p mruby/bin/mruby /usr/local/bin/
```

動作確認

```sh
mruby --version
```

以下が表示される

```sh
mruby 1.2.0 (2015-11-17)
```

### テストコードを実装するサンプルプログラムを用意する。

##### mruby.rb

```ruby
#!mruby

# 本番用コード
class SampleClass
  def initialize(request)
    @r = request
  end

  def get_filename
    @r.filename
  end

  def get_uri
    @r.uri
  end
end
```

このSampleClassはhttpリクエストを受け取り、その内容を出力するためのメソッドが実装されているものです。

### テストコードを実装する

上記コードに対して、テスト時の処理を以下のように追記する。
"# ---" で囲っている部分がその箇所です。

```ruby
#!mruby

# -----------------------------------
# テスト用の初期化処理
if Object.const_defined?(:MTest)
  class Apache
    class Request
	  attr_accessor :filename, :uri
	end
  end
end
# -----------------------------------

# 本番用コード
class SampleClass
  def initialize(request)
    @r = request
  end

  def get_filename
    @r.filename
  end

  def get_uri
    @r.uri
  end
end

# -----------------------------------
# テストコード

# テスト環境であれば実行
if Object.const_defined?(:MTest)
  class TestSampleClass < MTest::Unit::TestCase
    def setup
  	  @filename = "/var/www/html/test.php"
  	  @uri = "http://127.0.0.1/test.php"

  	  @request = Apache::Request.new
  	  @request.filename = @filename
  	  @request.uri = @uri
  	  @s = SampleClass.new @request
  	end

  	def test_get_filename
  	  str = @s.get_filename
  	  assert_equal(@filename, str)
  	end

  	def test_get_uri
  	  str = @s.get_uri
  	  assert_equal(@uri, str)
  	end
  end
  MTest::Unit.new.run
end
# -----------------------------------
```

- "if Object.const_defined?(:MTest)" の意味は、mrubyにmruby-mtestがビルドされているかを判断させています。mruby-mtestがビルドされているときのみ処理が実行されるため本番の環境でmruby-mtestを含めなければ本番で実行されることはありません。

- 今回作ったmrubyにはmod_mrubyやngx_mrubyで用意されているライブラリを含めてビルドしていないため "テスト用の初期化処理" でテストで使うクラスを実装しています。
  - もちろん、mrubyのビルド時にmod_mrubyやngx_mrubyのライブラリを "build_config.rb" 内で読み込ませれば必要ないです。

- "def setup" はテスト実行時に最初に実行される処理を記述します。今回はテストで使用するhttpリクエストを手動で作成しています。

- "assert_equal(@filename, str)" は "str" が "@filename" と同じであるべきとして定義しています。これに違反した場合はテストが失敗するということになります。

- "MTest::Unit.new.run" 最後にこれを実行してテストを行います。

### テストを実行してみる

```sh
mruby mruby.rb
```

実行結果

```sh
Finished tests in 0.000592s, 3378.3784 tests/s, 3378.3784 assertions/s.

2 tests, 2 assertions, 0 failures, 0 errors, 0 skips
```

これでmrubyもテストできるようになりました！
