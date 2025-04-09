helm repo add runai https://runai.jfrog.io/artifactory/api/helm/run-ai-charts --force-update
helm repo update
helm upgrade -i runai-cluster runai/runai-cluster -n runai \
--set controlPlane.url=michal.jordan.com \
--set controlPlane.clientSecret=XKClgWkbZxiZhywEGnEn6orRQejo1uj3 \
--set cluster.uid=5686ac7b-f8ed-4534-83c8-153ea3540505 \
--set cluster.url=michal.jordan.com --version="2.21.4" --create-namespace
