# Kubernetes Deployment
## of Prometheus,Grafana,Loki and AlertManager

Install kubectl
```
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl

chmod +x ./kubectl

sudo mv ./kubectl /usr/local/bin/kubectl
```

Use k3s for EC2 instance
```
curl -sfL https://get.k3s.io | sh -

mkdir ~/.kube/

touch ~/.kube/config

cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
```
Use minikube or kind for local
Url : https://minikube.sigs.k8s.io/docs/start/?arch=%2Flinux%2Fx86-64%2Fstable%2Fbinary+download
Url : https://kind.sigs.k8s.io/docs/user/quick-start/#installing-with-a-package-manager