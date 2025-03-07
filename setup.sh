#!/usr/bin/env bash

set -eo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

function variables_from_context() {
    # Create EKS cluster without nodes
    # Generate a new kubeconfig file in the local directory
    KUBECONFIG=".kubeconfig"

    # extract details form the ecktl configuration file
    CLUSTER_NAME=$(yq eval '.metadata.name' "${EKSCTL_CONFIG}")
    AWS_REGION=$(yq eval '.metadata.region' "${EKSCTL_CONFIG}")

    ACCOUNT_ID=$(${AWS_CMD} sts get-caller-identity | jq -r .Account)

    # use the default bucket?
    if [ -z "${CONTAINER_REGISTRY_BUCKET}" ]; then
        CONTAINER_REGISTRY_BUCKET="container-registry-${CLUSTER_NAME}-${ACCOUNT_ID}"
    fi

    CREATE_S3_BUCKET="false"
    if ! "${AWS_CMD}" s3api head-bucket --bucket "${CONTAINER_REGISTRY_BUCKET}" >/dev/null 2>&1; then
        CREATE_S3_BUCKET="true"
    fi

    export KUBECONFIG
    export CLUSTER_NAME
    export AWS_REGION
    export ACCOUNT_ID
    export CREATE_S3_BUCKET
    export CONTAINER_REGISTRY_BUCKET
}

function check_prerequisites() {
    EKSCTL_CONFIG=$1
    if [ ! -f "${EKSCTL_CONFIG}" ]; then
        echo "The eksctl configuration file ${EKSCTL_CONFIG} does not exist."
        exit 1
    else
        echo "Using eksctl configuration file: ${EKSCTL_CONFIG}"
    fi
    export EKSCTL_CONFIG

    if [ -z "${CERTIFICATE_ARN}" ]; then
        echo "Missing CERTIFICATE_ARN environment variable."
        exit 1;
    fi

    if [ -z "${DOMAIN}" ]; then
        echo "Missing DOMAIN environment variable."
        exit 1;
    fi

    AWS_CMD="aws"
    if [ -z "${AWS_PROFILE}" ]; then
        echo "Missing (optional) AWS profile."
        unset AWS_PROFILE
    else
        echo "Using the AWS profile: ${AWS_PROFILE}"
        AWS_CMD="aws --profile ${AWS_PROFILE}"
    fi
    export AWS_CMD

    if [ -z "${ROUTE53_ZONEID}" ]; then
        echo "Missing (optional) ROUTE53_ZONEID environment variable."
        echo "Please configure the CNAME with the URL of the load balancer manually."
    else
        echo "Using external-dns. No manual intervention required."
    fi
}

# Bootstrap AWS CDK - https://docs.aws.amazon.com/cdk/latest/guide/bootstrapping.html
function ensure_aws_cdk() {
    pushd /tmp > /dev/null 2>&1; cdk bootstrap "aws://${ACCOUNT_ID}/${AWS_REGION}"; popd > /dev/null 2>&1
}

function install() {
    check_prerequisites "$1"
    variables_from_context
    ensure_aws_cdk

    # Check the certificate exists
    if ! ${AWS_CMD} acm describe-certificate --certificate-arn "${CERTIFICATE_ARN}" --region "${AWS_REGION}" >/dev/null 2>&1; then
        echo "The secret ${CERTIFICATE_ARN} does not exist."
        exit 1
    fi

    if ! eksctl get cluster "${CLUSTER_NAME}" > /dev/null 2>&1; then
        # https://eksctl.io/usage/managing-nodegroups/
        eksctl create cluster --config-file "${EKSCTL_CONFIG}" --without-nodegroup --kubeconfig ${KUBECONFIG}
    else
        eksctl utils write-kubeconfig --cluster "${CLUSTER_NAME}"
    fi

    # Disable default AWS CNI provider.
    # The reason for this change is related to the number of containers we can have in ec2 instances
    # https://github.com/awslabs/amazon-eks-ami/blob/master/files/eni-max-pods.txt
    # https://docs.aws.amazon.com/eks/latest/userguide/pod-networking.html
    kubectl patch ds -n kube-system aws-node -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-calico": "true"}}}}}'
    # Install Calico.
    kubectl apply -f https://docs.projectcalico.org/manifests/calico-vxlan.yaml

    # Create secret with container registry credentials
    if [ -n "${IMAGE_PULL_SECRET_FILE}" ] && [ -f "${IMAGE_PULL_SECRET_FILE}" ]; then
        kubectl create secret generic gitpod-image-pull-secret \
            --from-file=.dockerconfigjson="${IMAGE_PULL_SECRET_FILE}" \
            --type=kubernetes.io/dockerconfigjson  >/dev/null 2>&1 || true
    fi

    if ${AWS_CMD} iam get-role --role-name "${CLUSTER_NAME}-region-${AWS_REGION}-role-eksadmin" > /dev/null 2>&1; then
        KUBECTL_ROLE_ARN=$(${AWS_CMD} iam get-role --role-name "${CLUSTER_NAME}-region-${AWS_REGION}-role-eksadmin" | jq -r .Role.Arn)
    else
        echo "Creating Role for EKS access"
        # Create IAM role and mapping to Kubernetes user and groups.
        POLICY=$(echo -n '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'; echo -n "$ACCOUNT_ID"; echo -n ':root"},"Action":"sts:AssumeRole","Condition":{}}]}')
        KUBECTL_ROLE_ARN=$(${AWS_CMD} iam create-role \
            --role-name "${CLUSTER_NAME}-region-${AWS_REGION}-role-eksadmin" \
            --description "Kubernetes role (for AWS IAM Authenticator for Kubernetes)." \
            --assume-role-policy-document "$POLICY" \
            --output text \
            --query 'Role.Arn')
    fi
    export KUBECTL_ROLE_ARN

    # check if the identity mapping already exists
    # Manage IAM users and roles https://eksctl.io/usage/iam-identity-mappings/
    if ! eksctl get iamidentitymapping --cluster "${CLUSTER_NAME}" --arn "${KUBECTL_ROLE_ARN}" > /dev/null 2>&1; then
        echo "Creating mapping from IAM role ${KUBECTL_ROLE_ARN}"
        eksctl create iamidentitymapping \
            --cluster "${CLUSTER_NAME}" \
            --arn "${KUBECTL_ROLE_ARN}" \
            --username eksadmin \
            --group system:masters
    fi

    # Create cluster nodes defined in the configuration file
    eksctl create nodegroup --config-file="${EKSCTL_CONFIG}"

    # Restart tigera-operator
    kubectl delete pod -n tigera-operator -l k8s-app=tigera-operator > /dev/null 2>&1

    MYSQL_GITPOD_USERNAME="gitpod"
    MYSQL_GITPOD_PASSWORD=$(openssl rand -hex 18)
    MYSQL_GITPOD_SECRET="mysql-gitpod-token"
    MYSQL_GITPOD_ENCRYPTION_KEY='[{"name":"general","version":1,"primary":true,"material":"4uGh1q8y2DYryJwrVMHs0kWXJlqvHWWt/KJuNi04edI="}]'
    SECRET_STORAGE="object-storage-gitpod-token"

    # generated password cannot excede 41 characters (RDS limitation)
    SSM_KEY="/gitpod/cluster/${CLUSTER_NAME}/region/${AWS_REGION}"
    ${AWS_CMD} ssm put-parameter \
        --overwrite \
        --name "${SSM_KEY}" \
        --type String \
        --value "${MYSQL_GITPOD_PASSWORD}" \
        --region "${AWS_REGION}" > /dev/null 2>&1

    # deploy CDK stacks
    cdk deploy \
        --context clusterName="${CLUSTER_NAME}" \
        --context region="${AWS_REGION}" \
        --context domain="${DOMAIN}" \
        --context certificatearn="${CERTIFICATE_ARN}" \
        --context identityoidcissuer="$(${AWS_CMD} eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.identity.oidc.issuer" --output text --region "${AWS_REGION}")" \
        --require-approval never \
        --outputs-file cdk-outputs.json \
        --all

    # TLS termination is done in the ALB.
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: https-certificates
spec:
  dnsNames:
  - ${DOMAIN}
  - '*.${DOMAIN}'
  - '*.ws.${DOMAIN}'
  duration: 4380h0m0s
  issuerRef:
    group: cert-manager.io
    kind: Issuer
    name: ca-issuer
  secretName: https-certificates
EOF

    echo "Create database secret..."
    kubectl create secret generic "${MYSQL_GITPOD_SECRET}" \
        --from-literal=encryptionKeys="${MYSQL_GITPOD_ENCRYPTION_KEY}" \
        --from-literal=host="$(jq -r '. | to_entries[] | select(.key | startswith("ServicesRDS")).value.MysqlEndpoint ' < cdk-outputs.json)" \
        --from-literal=password="${MYSQL_GITPOD_PASSWORD}" \
        --from-literal=port="3306" \
        --from-literal=username="${MYSQL_GITPOD_USERNAME}" \
        --dry-run=client -o yaml | \
        kubectl replace --force -f -

    echo "Create storage secret..."
    kubectl create secret generic "${SECRET_STORAGE}" \
        --from-literal=s3AccessKey="$(jq -r '. | to_entries[] | select(.key | startswith("ServicesRegistry")).value.AccessKeyId ' < cdk-outputs.json)" \
        --from-literal=s3SecretKey="$(jq -r '. | to_entries[] | select(.key | startswith("ServicesRegistry")).value.SecretAccessKey ' < cdk-outputs.json)" \
        --dry-run=client -o yaml | \
        kubectl replace --force -f -

    local CONFIG_FILE="${DIR}/gitpod-config.yaml"
    gitpod-installer init > "${CONFIG_FILE}"

    yq e -i ".certificate.name = \"https-certificates\"" "${CONFIG_FILE}"
    yq e -i ".domain = \"${DOMAIN}\"" "${CONFIG_FILE}"
    yq e -i ".metadata.region = \"${AWS_REGION}\"" "${CONFIG_FILE}"
    yq e -i ".database.inCluster = false" "${CONFIG_FILE}"
    yq e -i ".database.external.certificate.kind = \"secret\"" "${CONFIG_FILE}"
    yq e -i ".database.external.certificate.name = \"${MYSQL_GITPOD_SECRET}\"" "${CONFIG_FILE}"
    yq e -i '.workspace.runtime.containerdRuntimeDir = "/var/lib/containerd/io.containerd.runtime.v2.task/k8s.io"' "${CONFIG_FILE}"
    yq e -i ".containerRegistry.s3storage.bucket = \"${CONTAINER_REGISTRY_BUCKET}\"" "${CONFIG_FILE}"
    yq e -i ".containerRegistry.s3storage.certificate.kind = \"secret\"" "${CONFIG_FILE}"
    yq e -i ".containerRegistry.s3storage.certificate.name = \"${SECRET_STORAGE}\"" "${CONFIG_FILE}"
    yq e -i ".workspace.runtime.fsShiftMethod = \"shiftfs\"" "${CONFIG_FILE}"

    gitpod-installer \
        render \
        --config="${CONFIG_FILE}" > gitpod.yaml

    kubectl apply -f gitpod.yaml

    # remove shiftfs-module-loader container.
    # TODO: remove once the container is removed from the installer
    kubectl patch daemonset ws-daemon --type json -p='[{"op": "remove",  "path": "/spec/template/spec/initContainers/3"}]'
    # Patch proxy service to remove use of cloud load balancer. In EKS we use ALB.
    kubectl patch service   proxy     --type merge --patch \
"$(cat <<EOF
spec:
  type: NodePort
EOF
)"

    # wait for update of the ingress status
    until [ -n "$(kubectl get ingress gitpod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')" ]; do
        sleep 5
    done

    ALB_URL=$(kubectl get ingress gitpod -o json | jq -r .status.loadBalancer.ingress[0].hostname)
    if [ -n "${ALB_URL}" ];then
        printf '\nLoad balancer hostname: %s\n' "${ALB_URL}"
    fi
}

function uninstall() {
    check_prerequisites "$1"
    variables_from_context

    read -p "Are you sure you want to delete: Gitpod, Services/Registry, Services/RDS, Services, Addons, Setup (y/n)? " -n 1 -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if ! ${AWS_CMD} eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" > /dev/null; then
            exit 1
        fi

        KUBECTL_ROLE_ARN=$(${AWS_CMD} iam get-role --role-name "${CLUSTER_NAME}-region-${AWS_REGION}-role-eksadmin" | jq -r .Role.Arn)
        export KUBECTL_ROLE_ARN

        SSM_KEY="/gitpod/cluster/${CLUSTER_NAME}/region/${AWS_REGION}"

        cdk destroy \
            --context clusterName="${CLUSTER_NAME}" \
            --context region="${AWS_REGION}" \
            --context domain="${DOMAIN}" \
            --context certificatearn="${CERTIFICATE_ARN}" \
            --context identityoidcissuer="$(${AWS_CMD} eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.identity.oidc.issuer" --output text --region "${AWS_REGION}")" \
            --require-approval never \
            --force \
            --all \
        && cdk context --clear \
        && eksctl delete cluster "${CLUSTER_NAME}" \
        && ${AWS_CMD} ssm delete-parameter --name "${SSM_KEY}" --region "${AWS_REGION}"
    fi
}

function auth() {
    AUTHPROVIDERS_CONFIG=${1:="auth-providers-patch.yaml"}
    if [ ! -f "${AUTHPROVIDERS_CONFIG}" ]; then
        echo "The auth provider configuration file ${AUTHPROVIDERS_CONFIG} does not exist."
        exit 1
    else
        echo "Using the auth providers configuration file: ${AUTHPROVIDERS_CONFIG}"
    fi

    # Patching the configuration with the user auth provider/s
    kubectl --kubeconfig .kubeconfig patch configmap auth-providers-config --type merge --patch "$(cat ${AUTHPROVIDERS_CONFIG})"
    # Restart the server component
    kubectl --kubeconfig .kubeconfig rollout restart deployment/server
}

function main() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: $0 [--install|--uninstall]"
        exit
    fi

    case $1 in
        '--install')
            install "eks-cluster.yaml"
        ;;
        '--uninstall')
            uninstall "eks-cluster.yaml"
        ;;
        '--auth')
            auth "auth-providers-patch.yaml"
        ;;
        *)
            echo "Unknown command: $1"
            echo "Usage: $0 [--install|--uninstall]"
        ;;
    esac
    echo "done"
}

main "$@"
