# OwncloudOnGCP
This script creates a database and a NFS fileshare on GCP. It then sets up Owncloud containers on a GKE cluster

Prerequesite:
  - You need to have a shell that is connected to your project and also connected to you cluster using th following command:
  
  gcloud container clusters get-credentials [CLUSTER_NAME] --region [REGION] --project [PROJECT_NAME]


Once this is done, simply run the script using this command:

curl -s https://raw.githubusercontent.com/FredericGervais/OwncloudOnGCP/master/setup.sh | bash
