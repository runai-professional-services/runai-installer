helm repo add runai https://runai.jfrog.io/artifactory/api/helm/run-ai-charts --force-update
helm repo update
helm upgrade -i runai-cluster runai/runai-cluster -n runai \
--set controlPlane.url=192.168.0.203.sslip.io \
--set controlPlane.clientSecret=HvjiAOBxzjWrT2aoOJHM5DauqFm1qcii \
--set cluster.uid=f7779d7b-4426-4557-b126-63c582483ef8 \
--set cluster.url=192.168.0.203.sslip.io --version="2.24.75" --set global.customCA.enabled=true --create-namespace \
--set clusterConfig.global.ingress.ingressClass=haproxy
