---
author: "Takuma Kume"
title: "eBPF入門についてKixs vol.006で登壇した"
linktitle: "eBPF入門についてKixs vol.006で登壇した"
date: 2017-12-18T00:00:00+09:00
draft: false
highlight: true
tags: ["linux", "bpf"]
---

[GMOペパボ Advent Calendar 2017](https://qiita.com/advent-calendar/2017/pepabo) の18日目の記事です。

[九州インフラ交流勉強会(Kixs) Vol.006](https://kixs.connpass.com/event/69643/) というイベントで「eBPF入門」というタイトルで登壇した。
当日のスライドは以下。

<script async class="speakerdeck-embed" data-id="863e9f0eb2a64ac3bbb00f09ff5250bf" data-ratio="1.77777777777778" src="//speakerdeck.com/assets/embed.js"></script>

`BPF` とは <u>B</u>erkeley <u>P</u>acket <u>F</u>ilter の略で、 `tcpdump(1)` や `seccomp(2)` などに使われていてパケットやシステムコールのフィルタリングをするためのインターフェイスとして利用されている。
仕組みとしては、 Userspace で 作成した Bytecode を Kernel 内部で実行することでそれらを実現している。スライドにて図解しているのでぜひご覧いただければと思います。

今回のスライドは「eBPF(<u>E</u>xtended <u>B</u>erkeley <u>P</u>acket <u>F</u>ilter)入門」ということで拡張されたBPFの機能の一部や仕組みについてを触れています。

本エントリでは、学習の背景や調査した内容と今後のやっていきについて書く。

## eBPFを学習するに至った背景

仕事で大規模ホスティング環境の運用を行っていく中で、お客様にお貸ししている共有サーバが高負荷状態になるがその原因が掴みづらい問題がしばしば発生していた。

10月にGMOペパボにて開催された、[ペパボ・はてな技術大会@福岡](https://pepabo.connpass.com/event/65932/) で [ホスティングにおける安定運用のためのアクセスコントロール手法](https://speakerdeck.com/takumakume/hosuteinguniokeruan-ding-yun-yong-falsetamefalseakusesukontororushou-fa) というタイトルで登壇した日のこと。

イベント後の懇親会で、ホスティングの高負荷原因が掴みづらいという話をしていたところ、はてなの [@yoyogidesaiz](https://twitter.com/yoyogidesaiz) さんより `eBPF` の存在を教えていただいたことが始まりだった。

## BPFについて学習

当初、 `BPF` について全く知見がなく `tcpdump(1)` に使われていることすら知らない状況だった。まずはBPFについて知ることが必要だったため以下を参考にした。

  - BPF
    - [The BSD Packet Filter: A New Architecture for User-level Packet Capture](http://www.tcpdump.org/papers/bpf-usenix93.pdf)
  - tcpdump
    - [libpcap: An Architecture and Op2miza2on Methodology for Packet Capture](https://sharkfestus.wireshark.org/sharkfest.11/presentations/McCanne-Sharkfest'11_Keynote_Address.pdf)
  - seccomp
    - [seccompをmrubyで試す](http://udzura.hatenablog.jp/entry/2016/11/18/160020)


## eBPFについて学習

まずは、 eBPF が ClassicBPF(以下cBPF) に比べて何が違うのか、既存の手法に比べて何が優位なのか、何ができそうかを調べていった。
調査をしていくと eBPF は日本語の情報があまりなく、 Brendan Gregg 氏が多くの情報を公開してくださっていたためその付近を調べた。

  - [BPF: Tracing and more](https://www.slideshare.net/brendangregg/bpf-tracing-and-more)
  - [eBPF: One Small Step](http://www.brendangregg.com/blog/2015-05-15/ebpf-one-small-step.html)

Kernelのヘッダファイルを確認すると、[この](https://github.com/torvalds/linux/blob/v4.14/include/trace/events/bpf.h#L12)のように多くのことができるようだった。

```c
#define __PROG_TYPE_MAP(FN)	\
	FN(SOCKET_FILTER)	\
	FN(KPROBE)		\
	FN(SCHED_CLS)		\
	FN(SCHED_ACT)		\
	FN(TRACEPOINT)		\
	FN(XDP)			\
	FN(PERF_EVENT)		\
	FN(CGROUP_SKB)		\
	FN(CGROUP_SOCK)		\
	FN(LWT_IN)		\
	FN(LWT_OUT)		\
	FN(LWT_XMIT)
```

今回は、イメージが付きやすかった、Linux Kernelのトレース `KPROBE` と、パケットの制御 `XDP` に絞って調査することにした。

また、eBPFを利用したツール郡として [iovisor/bcc](https://github.com/iovisor/bcc) というPythonのバインディング実装があったためソースコードを参考にした。
Linux Kernel にも多くの [サンプルコード](https://github.com/torvalds/linux/tree/v4.14/samples/bpf) が同梱されていて、動作イメージを想像しやすかった。

> まずは、 eBPF が ClassicBPF(以下cBPF) に比べて何が違うのか、既存の手法に比べて何が優位なのか、何ができそうかを調べていった。

上記についてはスライドを是非ご覧ください。

### 【余談】トレースといえば `strace(1)` じゃん！

とか思って、 `strace(1)` の仕組みを調べてみたけどBPFとは関係なかった。せっかく動作内容を調べたのでここに貼っておく。

![strace](/img/2017-12-18/strace.png)

`ptrace(2)` というシステムコールがあり、解析対象プロセスにattachすることができる。
attach先はシステムコールを実行してから解析が終わるまでの間は瞬間的にプロセスが停止するようだった。

## 既存の技術についても学習機会が多かった

今回学習した範囲は、kprobeやuprobeを使った動的トレースや、XDPというパケット制御だった。

> kprobeやuprobeを使った動的トレース

こちらについては、そもそも `kprobe` 自体ほとんど知らなかったので、存在や仕組みを知ることができた。

> XDPというパケット制御

こちらについては、連想されるものとして `iptables` や `cBPF` があるが、eBPFがどう優れているかを調査するとおのずとその仕組みを学ぶことになるので非常に有意義だった。

## 発表後のフィードバックから得られたこと

例えば、KernelやUserspaceの動的トレースとしては `systemtap` など色々なツールがある。
調査当初ちらちらと見ていたが詳しいところが分かっていないのでeBPFがどこまで有用なのか判断がつかない場面があった。

これまで、あまり触れてこなかった既存のツールの仕組みやできることを把握していかねばならないと感じている。

既存のツール郡とコンポーネントのマッピングについては、 Brendan Gregg 氏の以下のツイートが参考になりそうなので今後学習していく。

<blockquote class="twitter-tweet" data-lang="ja"><p lang="en" dir="ltr">updated Linux tools diagram (PNG &amp; SVG) with recent bcc additions <a href="https://t.co/tMyCAxSzAS">https://t.co/tMyCAxSzAS</a> <a href="https://t.co/ek5CMy3oUU">pic.twitter.com/ek5CMy3oUU</a></p>&mdash; Brendan Gregg (@brendangregg) <a href="https://twitter.com/brendangregg/status/789923778960633856?ref_src=twsrc%5Etfw">2016年10月22日</a></blockquote>
<script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>

### 今後について

- eBPFについては、まだまだ触り部分しか触れていないので継続して調べていく。
- eBPFの有用性について、既存の技術を理解した上で語れるようになること。
- eBPFを仕事に活かしていく時に、どういった課題を解決できるか検討すること。この内容については、12/23の [Web System Architecture研究会](http://websystemarchitecture.hatenablog.jp/entry/2017/11/16/182041) で発表したいと考えている。
