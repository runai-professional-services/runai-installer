helm repo add runai https://helm.ngc.nvidia.com/nvidia/runai --username $oauthtoken --password <NGC_API_KEY> --force-update
helm repo update
helm upgrade -i runai-cluster runai/runai-cluster -n runai \
--set controlPlane.url=192.168.0.201.sslip.io \
--set controlPlane.clientSecret=g1zEovTl0FIHKkvhr7JDrsZ5kdL50nIY \
--set cluster.uid=67d82953-e8a2-4cb8-b4af-962229cea046 \
--set cluster.url=192.168.0.201.sslip.io --version="2.24.65" --set global.customCA.enabled=true --create-namespace \
--set clusterConfig.global.ingress.ingressClass=haproxy
