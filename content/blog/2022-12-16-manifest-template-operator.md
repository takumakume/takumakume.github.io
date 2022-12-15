---
author: "Takuma Kume"
title: "任意のmanifestにgo-templateを埋め込めるOperatorを実装した"
linktitle: "任意のmanifestにgo-templateを埋め込めるOperatorを実装した"
date: 2022-12-16T00:00:00+09:00
draft: false
highlight: true
tags: ["cloudnative", "kubernetes"]
---

[GMOペパボエンジニア Advent Calendar 2022](https://adventar.org/calendars/7722) の 2022/12/16 のエントリです。

今回は kubebuilder を用いて自作した Kubernetes Operator の記事を書きます。任意の manifest に go-template を埋め込めるOperatorを実装しました。

https://github.com/takumakume/manifest-template-operator

YAMLを見ていただいたほうが分かりやすいと思うのでサンプルを示します。

```yaml
apiVersion: manifest-template.takumakume.github.io/v1alpha1
kind: ManifestTemplate
metadata:
  name: sample-svc
spec:
  apiVersion: v1
  kind: Service
  metadata:
    name: sample-svc
    namespace: "{{ .Self.ObjectMeta.Namespace }}"
  spec:
    ports:
    - name: "http"
      port: 80
    selector:
      app: test1
      ns: "{{ .Self.ObjectMeta.Namespace }}"
```

この manifest を `test` namespace にデプロイすると、以下のリソースが生成されます。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sample-svc
  namespace: "test" # go-template が render される
spec:
  ports:
  - name: "http"
    port: 80
  selector:
    app: test1
    ns: "test" # go-template が render される
```

`.Self` の中に、 `ManifestTemplate` リソースの構造体が入っています。 `.Self.ObjectMeta.Namespace` には `ManifestTemplate` がデプロイされた namespace が入っています。

## なぜ必要だったか

チームでは kubernetes 上の Web アプリケーションを Pull Request ベースで開発しており、 Production にリリースする前に Staging (本番相当の環境) で動作確認をしています。加えて Staging 環境を Pull Request ごとに自動生成して動作確認がスムーズに行える仕組みを作っています。 (Preview 環境と呼ぶことにします)

kubernetes の manifest は、以下のように kustomize を用いて管理しています。

```
├── base
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── secret.yaml
└── overlays
    ├── production
    │   ├── kustomization.yaml
    │   ├── deployment_patch.yaml
    │   └── ingress.yaml
    └── staging
        ├── kustomization.yaml
        └── ingress.yaml
```

Preview 環境は Staging用の manifest を ArgoCD + ApplicationSet を用いて Pull Request ごとの namespace にデプロイすることで実現しています。

そうすると、以下のような Ingress リソースなどの Hostname をいい感じに差し替えながらデプロイする必要がありますが、うまく管理する方法がありませんでした。

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sample
  namespace: pr-105
spec:
tls:
- hosts:
  - "app-pr-105.example.com"
  secretName: example-com-tls
rules:
- host: "app-pr-105.example.com"
  http:
  paths:
  - backend:
    service:
      name: sample
      port:
        number: 80
    path: /
    pathType: Prefix
```

この問題を解決するために [takumakume/manifest-template-operator](https://github.com/takumakume/manifest-template-operator) を実装しました。

## Operator ができるまで

実はこの Operator を作る前に [takumakume/ingress-template-operator](https://github.com/takumakume/ingress-template-operator) という、Ingressリソースの生成に特化した Operator を開発しました。

以下のようなYAMLでIngressを動的に生成できます。

```yaml
apiVersion: ingress-template.takumakume.github.io/v1alpha1
kind: IngressTemplate
metadata:
  name: example
  namespace: hoge
spec:
  ingressAnnotations:
    cert-manager.io/cluster-issuer: example-com-issuer
    key: "This namespace is {{ .Metadata.Namespace }}"
  ingressLabels:
    key: "This namespace is {{ .Metadata.Namespace }}"
  ingressSpecTemplate:
    tls:
    - hosts:
        - "www-{{ .Metadata.Namespace }}.example.com"
      secretName: example-com-tls
    rules:
    - host: "www-{{ .Metadata.Namespace }}.example.com"
      http:
        paths:
        - backend:
            service:
              name: example
              port:
                number: 80
          path: /
          pathType: Prefix
```

しかし、以下の理由でボツになりました。

1. Ingress に特化しているため Gateway API の HTTPRoute リソース等に対応できない。
2. `spec.ingressSpecTemplate` に Ingress CRD の Spec 構造体を埋め込んでいた。


### 1. Ingress に特化しているため Gateway API の HTTPRoute リソース等に対応できない。

Ingressによる外部公開だけでなく、より高機能かつ汎用的な [Gateway API](https://gateway-api.sigs.k8s.io/) も採用し始めました。

このように、対応するCRDが増えた時に同じようなOperatorを作りたくはない。

### 2. `spec.ingressSpecTemplate` に Ingress CRD の Spec 構造体を埋め込んでいた。

CRDの一部に以下のように他のCRDの構造体を埋め込んでいるパターンです。こうすることで、IngressのSpecと同じ構造を持つことができます。

```go
// IngressTemplateSpec defines the desired state of IngressTemplate
type IngressTemplateSpec struct {
	// IngressSpec Template for Ingress.Spec
	// +kubebuilder:validation:Required
	IngressSpecTemplate networkingv1.IngressSpec `json:"ingressSpecTemplate"`
:
```

なぜこのパターンが良くなかったかというと、以下のようなパターンがあるからでした。

https://github.com/kubernetes-sigs/gateway-api/blob/df03bd58002fcf01ee3ffeba97edc1f0c67fb386/apis/v1beta1/shared_types.go#L366-L369

```go
// +kubebuilder:validation:MinLength=1
// +kubebuilder:validation:MaxLength=253
// +kubebuilder:validation:Pattern=`^(\*\.)?[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`
type Hostname string
```

この例では Gateway API の HTTPRoute リソースの Hostname で、厳密な Hostname pattern の Validation が入っています。そうすると、Validationによって以下のような go-template を埋め込んだ状態で kubernetes 上にデプロイすることができなくなります。

```yaml
spec:
  hostnames:
   - "app-{{ .Self.ObjectMeta.Namespace }}.example.com"
```

以上の理由で、Operatorを作り直したのでした。

## どのような仕組みで実現しているか

### どんなCRDでも使えるようにする


```yaml
apiVersion: manifest-template.takumakume.github.io/v1alpha1
kind: ManifestTemplate
metadata:
  name: sample-svc
spec:
  apiVersion: v1
  kind: Service
  metadata:
    name: sample-svc
    namespace: "{{ .Self.ObjectMeta.Namespace }}"
  spec:
    ports:
    - name: "http"
      port: 80
    selector:
      app: test1
      ns: "{{ .Self.ObjectMeta.Namespace }}"
```

この `.spec.spec` がどのような形式でも受け入れる必要があります。そのためにはいくつかの手順が必要です。

まずは、該当の要素に `+kubebuilder:pruning:PreserveUnknownFields` を付与します。こうすることで、API Serverが未知のフィールドを削除するのを防ぎます。

```go
type ManifestTemplateSpec struct {
    :
	// Spec generate manifest spec
	// +kubebuilder:pruning:PreserveUnknownFields
	// +optional
	Spec Spec `json:"spec"`
}
```

次に、上記のSpec構造体の実装をします。

任意のHashということになるのですが、Goでいうところの `map[string]interface{}` は直接CRDの要素に入れることはできません。以下のエラーとなってしまいます。

> not a supported map value type: *ast.InterfaceType

以下の様な実装を行い、内部で処理できるようにします。

```go
// +k8s:deepcopy-gen=false
type Spec struct {
	Object map[string]interface{} `json:"-"`
}

func (u *Spec) MarshalJSON() ([]byte, error) {
	return json.Marshal(u.Object)
}

func (u *Spec) UnmarshalJSON(data []byte) error {
	m := make(map[string]interface{})
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}

	u.Object = m

	return nil
}

func (u *Spec) DeepCopyInto(out *Spec) {
	out.Object = runtime.DeepCopyJSON(u.Object)
}
```

最後に、 `.spec.spec` から受け取った `map[string]interface{}` をサーバに適用できる状態にします。この中身をそのCRDに適合した構造体にマッピングしてやると簡単ですが今回はそうもいきません。

その場合は [k8s.io/apimachinery/pkg/apis/meta/v1/unstructured](https://pkg.go.dev/k8s.io/apimachinery/pkg/apis/meta/v1/unstructured) を使います。これは、構造体が登録されていないオブジェクトを操作するための構造体です。

```go
u := &unstructured.Unstructured{}
u.SetKind(manifestTemplate.Spec.Kind)
u.SetAPIVersion(manifestTemplate.Spec.APIVersion)
u.SetName(manifestTemplate.Spec.ObjectMeta.Name)
u.SetNamespace(manifestTemplate.Spec.ObjectMeta.Namespace)
u.SetLabels(manifestTemplate.Spec.ObjectMeta.Labels)
u.SetAnnotations(manifestTemplate.Spec.ObjectMeta.Annotations)
u.Object["spec"] = manifestTemplate.Spec.Spec.Object
```

このようにマッピングしてAPI Serverに送信することで適用することができます。

### `map[string]interface{}` 全体に対して go-tempate を適用する

深さも要素数も不明な `map[string]interface{}` に対して go-template を見つけて render して下記戻す処理をどうするかということです。

```go
map[string]interface{}{
	"metadata": []map[string]interface{}{
		"name": "sample",
		"annotations": []map[string]interface{}{
			"ns": "{{ .Self.ObjectMeta.Namespace }}",
		},
	},
	"spec": []map[string]interface{}{
		"ports": []map[string]interface{}{
			{
				"name": "http",
				"port": 80,
			},
		},
		"selector": map[string]interface{}{
			"app": "test1",
			"ns":  "{{ .Self.ObjectMeta.Namespace }}",
		},
	},
},
```

今回は一度 `yaml.Marshal` して String にしたところを一発で go-template を適用し、 `yaml.Unmarshal` するといった方法を取りました。データ構造を気にせずにできて便利でした。

## Reconcil時にどんなCRDでも差分を適用する

`ManifestTemplate` リソースを変更したときに、差分があれば既存リソースをUpdateしたいです。

Templateから生成したYAMLと既存リソースの比較を行うと以下の課題が発生します。

- YAMLと既存リソースをそれぞれ `map[string]interface{}` に変換した場合に、要素の順序が違うため単純な比較ができない
- 適用済みの既存リソースは一部のデフォルト値が補完されているため、Templateから生成した期待値とは若干異なる

解決方法としては、`ManifestTemplate` CRDに `.status.lastAppliedConfigration` を設け、最後に生成したYAMLの文字列を格納しました。

これによって、生成結果が変わる時だけUpdateをすることができました。


## この他の解決方法

### アプリケーションの manifest を Helm 化する

Preview 環境の Hostname の差分を Helm の Value で吸収するパターンは良さそうと思います。今回はこの方法は見送りました。理由は以下です。

- manifest は、素朴な Deployment と Ingress or Gateway API があるだけのような非常にシンプルな作りでした。Helm  Template の開発より直感的でシンプルな kustomize が管理しやすかったという点があります。
- manifest の管理は kubernetes 初学者のアプリケーションエンジニアも参画します。利便性より認知負荷のほうが高いと判断しました。

### Preview環境のみ SaaS　に投げる

SaaSを使えばPull RequestごとのPreview環境を簡単に立ち上げることはできます。

今回の目的として、リリース前の Staging 動作確認は極力 Production の kubernetes インフラと同じ構成で限りなく本番に近い状態で動作確認をすることにありました。そのため、Preview環境だけSaaSで簡単に確認する手法は取りませんでした。
