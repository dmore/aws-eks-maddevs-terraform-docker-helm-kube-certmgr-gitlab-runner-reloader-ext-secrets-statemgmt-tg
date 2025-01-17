locals {
  eks_worker_tags = {
    "k8s.io/cluster-autoscaler/enabled"       = "true"
    "k8s.io/cluster-autoscaler/${local.name}" = "owned"
  }

  eks_map_roles = [
    {
      rolearn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/administrator"
      username = "administrator"
      groups   = ["system:masters"]
    }
  ]
}

data "aws_ami" "eks_default_bottlerocket" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["bottlerocket-aws-k8s-${var.eks_cluster_version}-x86_64-*"]
  }
}

#tfsec:ignore:aws-vpc-no-public-egress-sgr tfsec:ignore:aws-eks-enable-control-plane-logging tfsec:ignore:aws-eks-encrypt-secrets tfsec:ignore:aws-eks-no-public-cluster-access tfsec:ignore:aws-eks-no-public-cluster-access-to-cidr
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.12.0"

  cluster_name              = local.name
  cluster_version           = var.eks_cluster_version
  subnet_ids                = module.vpc.private_subnets
  control_plane_subnet_ids  = module.vpc.intra_subnets
  enable_irsa               = true
  manage_aws_auth_configmap = true
  create_aws_auth_configmap = false
  aws_auth_roles            = local.eks_map_roles
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent              = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.aws_ebs_csi_driver.iam_role_arn
    }
  }

  cluster_enabled_log_types              = var.eks_cluster_enabled_log_types
  cloudwatch_log_group_retention_in_days = var.eks_cloudwatch_log_group_retention_in_days

  vpc_id = module.vpc.vpc_id

  cluster_endpoint_public_access       = var.eks_cluster_endpoint_public_access
  cluster_endpoint_private_access      = var.eks_cluster_endpoint_private_access
  cluster_endpoint_public_access_cidrs = var.eks_cluster_endpoint_only_pritunl ? ["${module.pritunl[0].pritunl_endpoint}/32"] : ["0.0.0.0/0"]

  self_managed_node_group_defaults = {
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          delete_on_termination = true
          encrypted             = false
          volume_size           = 100
          volume_type           = "gp3"
        }

      }
    }
    iam_role_additional_policies = var.eks_workers_additional_policies
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 1
      instance_metadata_tags      = "disabled"
    }
    iam_role_attach_cni_policy = false
  }
  self_managed_node_groups = {
    spot = {
      name          = "${local.name}-spot"
      iam_role_name = "${local.name}-spot"
      desired_size  = var.node_group_spot.desired_capacity
      max_size      = var.node_group_spot.max_capacity
      min_size      = var.node_group_spot.min_capacity
      subnet_ids    = module.vpc.private_subnets

      bootstrap_extra_args       = "--kubelet-extra-args '--node-labels=eks.amazonaws.com/capacityType=SPOT  --node-labels=nodegroup=spot'"
      capacity_rebalance         = var.node_group_spot.capacity_rebalance
      use_mixed_instances_policy = var.node_group_spot.use_mixed_instances_policy
      mixed_instances_policy     = var.node_group_spot.mixed_instances_policy

      tags = local.eks_worker_tags
    },
    ondemand = {
      name          = "${local.name}-ondemand"
      iam_role_name = "${local.name}-ondemand"
      desired_size  = var.node_group_ondemand.desired_capacity
      max_size      = var.node_group_ondemand.max_capacity
      min_size      = var.node_group_ondemand.min_capacity
      instance_type = var.node_group_ondemand.instance_type
      subnet_ids    = module.vpc.private_subnets

      bootstrap_extra_args       = "--kubelet-extra-args '--node-labels=eks.amazonaws.com/capacityType=ON_DEMAND --node-labels=nodegroup=ondemand'"
      capacity_rebalance         = var.node_group_ondemand.capacity_rebalance
      use_mixed_instances_policy = var.node_group_ondemand.use_mixed_instances_policy
      mixed_instances_policy     = var.node_group_ondemand.mixed_instances_policy

      tags = local.eks_worker_tags
    },
    ci = {
      name          = "${local.name}-ci"
      iam_role_name = "${local.name}-ci"
      desired_size  = var.node_group_ci.desired_capacity
      max_size      = var.node_group_ci.max_capacity
      min_size      = var.node_group_ci.min_capacity
      subnet_ids    = module.vpc.private_subnets

      bootstrap_extra_args       = "--kubelet-extra-args '--node-labels=eks.amazonaws.com/capacityType=SPOT  --node-labels=nodegroup=ci --register-with-taints=nodegroup=ci:NoSchedule'"
      capacity_rebalance         = var.node_group_ci.capacity_rebalance
      use_mixed_instances_policy = var.node_group_ci.use_mixed_instances_policy
      mixed_instances_policy     = var.node_group_ci.mixed_instances_policy

      tags = merge(local.eks_worker_tags, { "k8s.io/cluster-autoscaler/node-template/label/nodegroup" = "ci" })
    },
    bottlerocket = {
      name          = "${local.name}-bottlerocket"
      iam_role_name = "${local.name}-bottlerocket"
      desired_size  = var.node_group_br.desired_capacity
      max_size      = var.node_group_br.max_capacity
      min_size      = var.node_group_br.min_capacity
      subnet_ids    = module.vpc.private_subnets

      platform                   = "bottlerocket"
      ami_id                     = data.aws_ami.eks_default_bottlerocket.id
      bootstrap_extra_args       = <<-EOT
          [settings.host-containers.admin]
          enabled = false

          [settings.host-containers.control]
          enabled = true

          [settings.kubernetes.node-labels]
          "eks.amazonaws.com/capacityType" = "SPOT"
          "nodegroup" = "bottlerocket"

          [settings.kubernetes.node-taints]
          "nodegroup" = "bottlerocket:NoSchedule"
          EOT
      capacity_rebalance         = var.node_group_br.capacity_rebalance
      use_mixed_instances_policy = var.node_group_br.use_mixed_instances_policy
      mixed_instances_policy     = var.node_group_br.mixed_instances_policy

      tags = merge(local.eks_worker_tags, { "k8s.io/cluster-autoscaler/node-template/label/nodegroup" = "bottlerocket" })
    }
  }
  fargate_profiles = {
    default = {
      name = "fargate"

      selectors = [
        {
          namespace = "fargate"
        }
      ]

      subnets = module.vpc.private_subnets

      tags = merge(local.tags, {
        Namespace = "fargate"
      })
    }
  }

  tags = { "ClusterName" = local.name }
}

module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.17.0"

  role_name             = "${local.name}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = local.tags
}

module "aws_ebs_csi_driver" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.17.0"

  role_name             = "${local.name}-aws-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}
