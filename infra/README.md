# Turn EKS on and off super quickly with this repo!

You just need a working AWS account (with your AWS CLI already set up).

1. Turn on the cluster (has 2 t3.medium machines currently):
```bash
cd infra
chmod +x up.sh down.sh
./up.sh
```

2. When you're done, turn it off!
```bash
./down.sh
```
