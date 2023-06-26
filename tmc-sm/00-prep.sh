#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 gen-cert|prep|import-cli|import-packages|post-install"
    exit 1
fi

yq eval '.' ./templates/values-template.yaml
export yaml_check=$?

if [ $yaml_check -eq 0 ]; then
    echo "Valid yaml structure for: values-template.yaml . Continuing."
else
    echo ""
    echo "Invalid yaml structure for: values-template.yaml . Check values-template.yaml"
    exit 1
fi

export TLD_DOMAIN=$(yq eval '.tld_domain' ./templates/values-template.yaml)
export DOMAIN=*.$TLD_DOMAIN
export std_repo=$(yq eval '.std_repo' ./templates/values-template.yaml)
export tmc_repo=$(yq eval '.tmc_repo' ./templates/values-template.yaml)
export TMC_SM_DL_URL="https://artifactory.eng.vmware.com/artifactory/tmc-generic-local/bundle-$tmc_repo.tar"

if [ "$1" = "prep" ]; then
    echo prep
    mkdir -p airgapped-files/images
    wget -P airgapped-files/ "$TMC_SM_DL_URL"
    templates/carvel.sh download
    imgpkg copy -b projects.registry.vmware.com/tkg/packages/standard/repo:$std_repo --to-tar airgapped-files/$std_repo.tar --include-non-distributable-layers --concurrency 30
    imgpkg copy -i ghcr.io/carvel-dev/kapp-controller@sha256:8011233b43a560ed74466cee4f66246046f81366b7695979b51e7b755ca32212 --to-tar=airgapped-files/images/kapp-controller.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/tools/busybox:latest --to-tar=airgapped-files/images/busybox.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/tools/openldap:1.2.4 --to-tar=airgapped-files/images/openldap.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/sample-app/postgres:latest --to-tar=airgapped-files/images/postgres.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/sample-app/mongo:latest --to-tar=airgapped-files/images/mongo.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/sample-app/redis:latest --to-tar=airgapped-files/images/redis.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/sample-app/elasticsearch:7.2.1 --to-tar=airgapped-files/images/elasticsearch.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/sample-app/bitnami-shell --to-tar=airgapped-files/images/bitnami-shell.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/sample-app/mysql:5.7 --to-tar=airgapped-files/images/mysql.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/sample-app/rabbitmq:3.8 --to-tar=airgapped-files/images/rabbitmq.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/sample-app/sample-app:v0.3.27 --to-tar=airgapped-files/images/sample-app.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/tools/gitea:1.13.2 --to-tar=airgapped-files/images/gitea.tar --concurrency 30
    imgpkg copy -i projects.registry.vmware.com/tanzu_meta_pocs/extensions/kibana:7.2.1 --to-tar=airgapped-files/images/kibana.tar --concurrency 30
    git clone https://github.com/gorkemozlu/tanzu-gitops airgapped-files/tanzu-gitops && rm -rf airgapped-files/tanzu-gitops/.git
elif [ "$1" = "import-cli" ]; then
    echo import-cli
    templates/carvel.sh install
elif [ "$1" = "import-packages" ]; then
    echo import-packages
    if [ -f tmc-ca.crt ] ; then
        export TMC_CA_CERT=$(cat ./tmc-ca.crt)
        cp tmc-ca.crt /etc/ssl/certs/
        echo "required files exist, continuing."
    else
        echo "no tmc-ca.crt fall back to values-template.yaml"
        export TMC_CA_CERT=$(yq eval '.trustedCAs.tmc_ca' ./templates/values-template.yaml)
        export OTHER_CA_CERT=$(yq eval '.trustedCAs.other_ca' ./templates/values-template.yaml)
        export ALL_CA_CERT=$(echo -e "$TMC_CA_CERT""\n""$OTHER_CA_CERT")
        echo "$ALL_CA_CERT" > ./all-ca.crt
        echo "$ALL_CA_CERT" > /etc/ssl/certs/all-ca.crt
    fi
    export HARBOR_URL=$(yq eval '.harbor.fqdn' ./templates/values-template.yaml)
    export HARBOR_USER=$(yq eval '.harbor.user' ./templates/values-template.yaml)
    export HARBOR_PASS=$(yq eval '.harbor.pass' ./templates/values-template.yaml)
    export HARBOR_CERT=$(echo | openssl s_client -connect $HARBOR_URL:443 2>&1 | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p')
    openssl verify -CAfile <(echo "$ALL_CA_CERT") <(echo "$HARBOR_CERT")
    export harbor_cert_check=$?
    if [ $harbor_cert_check -eq 0 ]; then
        echo "Valid Harbor Cert , Continuing."
    else
        echo ""
        echo "INVALID Harbor Cert , Check Harbor Cert and CA Cert."
        exit 1
    fi
    tar -xvf airgapped-files/bundle*.tar
    export IMGPKG_REGISTRY_USERNAME=$HARBOR_USER && export IMGPKG_REGISTRY_PASSWORD=$HARBOR_PASS &&  export IMGPKG_REGISTRY_HOSTNAME=$HARBOR_URL
    curl -u "${IMGPKG_REGISTRY_USERNAME}:${IMGPKG_REGISTRY_PASSWORD}" -X POST -H "content-type: application/json" "https://$HARBOR_URL/api/v2.0/projects" -d "{\"project_name\": \"tmc\", \"public\": true, \"storage_limit\": -1 }" -k
    ./tmc-sm push-images harbor --project $HARBOR_URL/tmc --username $HARBOR_USER --password $HARBOR_PASS --concurrency 10
    imgpkg copy --tar airgapped-files/$std_repo.tar --to-repo $HARBOR_URL/tmc/498533941640.dkr.ecr.us-west-2.amazonaws.com/packages/standard/repo --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/kapp-controller.tar --to-repo $HARBOR_URL/tmc/kapp-controller --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/busybox.tar --to-repo $HARBOR_URL/tmc/busybox --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/openldap.tar --to-repo $HARBOR_URL/tmc/openldap --include-non-distributable-layers
    curl -u "${IMGPKG_REGISTRY_USERNAME}:${IMGPKG_REGISTRY_PASSWORD}" -X POST -H "content-type: application/json" "https://$HARBOR_URL/api/v2.0/projects" -d "{\"project_name\": \"apps\", \"public\": true, \"storage_limit\": -1 }" -k
    imgpkg copy --tar airgapped-files/images/postgres.tar --to-repo $HARBOR_URL/apps/postgres --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/mongo.tar --to-repo $HARBOR_URL/apps/mongo --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/redis.tar --to-repo $HARBOR_URL/apps/redis --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/elasticsearch.tar --to-repo $HARBOR_URL/apps/elasticsearch --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/bitnami-shell.tar --to-repo $HARBOR_URL/apps/bitnami-shell --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/mysql.tar --to-repo $HARBOR_URL/apps/mysql --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/rabbitmq.tar --to-repo $HARBOR_URL/apps/rabbitmq --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/sample-app.tar --to-repo $HARBOR_URL/apps/sample-app --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/gitea.tar --to-repo $HARBOR_URL/apps/gitea --include-non-distributable-layers
    imgpkg copy --tar airgapped-files/images/kibana.tar --to-repo $HARBOR_URL/apps/kibana --include-non-distributable-layers
    export es_old_image='projects.registry.vmware.com/tanzu_meta_pocs/extensions/elasticsearch:7.2.1' && export es_new_image=$HARBOR_URL/apps/elasticsearch:7.2.1 && sed -i -e "s~$es_old_image~$es_new_image~g" airgapped-files/tanzu-gitops/tmc-cg/apps/efk/elasticsearch.yaml
    export kb_old_image='projects.registry.vmware.com/tanzu_meta_pocs/extensions/kibana:7.2.1' && export kb_new_image=$HARBOR_URL/apps/kibana:7.2.1 && sed -i -e "s~$kb_old_image~$kb_new_image~g" airgapped-files/tanzu-gitops/tmc-cg/apps/efk/kibana.yaml
elif [ "$1" = "gen-cert" ]; then
    templates/gen-cert.sh
elif [ "$1" = "post-install" ]; then
    kubectl get httpproxy -A
    echo "-------------------"
    kubectl get svc -A|grep LoadBalancer
    echo "-------------------"
    echo "on vSphere 8, run below command on supervisor level before creating workload cluster "
    echo " "
    echo "ytt -f templates/values-template.yaml -f templates/vsphere-8/cluster-config.yaml | kubectl apply -f -"
fi