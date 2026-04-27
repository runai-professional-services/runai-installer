helm repo add runai https://runai.jfrog.io/artifactory/api/helm/run-ai-charts --force-update
helm repo update
helm upgrade -i runai-cluster runai/runai-cluster -n runai \
--set controlPlane.url=runai.apps.kirson-openshift-oneclick.runailabs-ps.com \
--set controlPlane.clientSecret=qvOXuiNItPqPMaw2oWocsYMs1U6Sg7cg \
--set cluster.uid=eddfbfe1-b7eb-4dee-9cb5-53f9cdb93898 \
--set cluster.url=runai.apps.kirson-openshift-oneclick.runailabs-ps.com --version="2.24.70" --set global.customCA.enabled=true --create-namespace \
--set clusterConfig.global.ingress.ingressClass=haproxy
