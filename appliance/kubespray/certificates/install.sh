helm repo add runai https://runai.jfrog.io/artifactory/api/helm/run-ai-charts --force-update
helm repo update
helm upgrade -i runai-cluster runai/runai-cluster -n runai \
--set controlPlane.url=single-dgx.kirson.lab \
--set controlPlane.clientSecret=aFgn9e1rQJ82FpQ985FrC0GQ9nGLpaFA \
--set cluster.uid=83faa5e0-d8d2-4cdc-8e97-8d3851b74fbd \
--set cluster.url=single-dgx.kirson.lab --version="2.20.22" --set global.customCA.enabled=true --create-namespace
