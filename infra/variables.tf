variable "student_name" {
  description = "Your name, lowercase, no spaces (keeps your resources unique)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "k8s_version" {
  description = "Kubernetes version. Use one in EKS STANDARD support to avoid the 6x extended-support fee. Check: <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html>"
  type        = string
  default     = "1.33"
}

# Node count knobs (used by Terraform; Option B changes these live)
variable "desired_nodes" {
  type    = number
  default = 2
}
variable "min_nodes" {
  type    = number
  default = 1
}
variable "max_nodes" {
  type    = number
  default = 3
}