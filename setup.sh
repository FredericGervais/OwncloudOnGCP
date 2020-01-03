#
# Description : This script creates a database and a NFS fileshare on
#               GCP. It then sets-up Owncloud containers on a
#               kubernetes cluster
# 
# Author      : Frederic Gervais
# Date        : 2019/12/27
#

IMAGE=owncloud/server:latest
CONTAINER_PORT=8080
NAME=owncloud
DB_USERNAME=root
DB_PREFIX=oc_
STORAGE_NAME=NFSvol
STORAGE_TB_SIZE=2
STORAGE_NETWORK=default
REGION=us-east4

## Auto-filled variables

DB_HOST_NAME=${NAME}-database-${RANDOM}
DB_NAME=$NAME
DB_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
##
LOWER_CASE=$(echo $STORAGE_NAME | tr '[:upper:]' '[:lower:]')
STORAGE_INSTANCE_ID=${LOWER_CASE}-${RANDOM}${RANDOM}
##
ZONES=($(gcloud compute zones list --filter="REGION:($REGION)" --format="value(name)"))
ZONE=${ZONES[0]}
##

#
# Create a Filestore instance to store the data
#
echo [+] Creating a Filestore instance to store the data

gcloud filestore instances create $STORAGE_INSTANCE_ID \
--zone=$ZONE \
--tier=STANDARD \
--file-share=name=$STORAGE_NAME,capacity=${STORAGE_TB_SIZE}TB \
--network=name=$STORAGE_NETWORK

#
# Create a MySQL instance on GCP
#
echo [+] Creating a MySQL instance

gcloud services enable servicenetworking.googleapis.com
gcloud beta sql instances create $DB_HOST_NAME \
--region $REGION \
--network=default \
--no-assign-ip \
--tier db-n1-standard-4 \
--availability-type REGIONAL \
--enable-bin-log

#
# Create a database on the MySQL instance
#
echo [+] Creating a database on the MySQL instance

gcloud sql databases create $DB_NAME \
--instance=$DB_HOST_NAME \
--charset=utf8 \
--collation=utf8_general_ci

#
# Set a known password to the database user
#
FOUND=
FOUND=$(gcloud sql users list --instance=$DB_HOST_NAME --format='value(name)' | grep $DB_USERNAME)

if [ -z $FOUND ]; then
  echo [+] Creating the database user : $DB_USERNAME
  
  gcloud sql users create $DB_USERNAME \
--instance=$DB_HOST_NAME \
--password=$DB_PASSWORD
else
  echo [+] Setting a known password to the database user : $DB_USERNAME
  
  gcloud sql users set-password $DB_USERNAME \
--host=% \
--instance=$DB_HOST_NAME \
--password=$DB_PASSWORD
fi

#
# Get the IP of the MySQL instance and the Filestore instance
#
echo -n [+] Getting the IP of the MySQL instance :
DB_HOST=$(gcloud sql instances describe $DB_HOST_NAME | grep ipAddress: | grep -oP '\d+.\d+.\d+.\d+')
echo " $DB_HOST"
echo -n [+] Getting the IP of the Filestore instance :
STORAGE_HOST=$(gcloud filestore instances describe $STORAGE_INSTANCE_ID --zone $ZONE | grep -A1 ipAddresses: | grep -oP '\d+.\d+.\d+.\d+')
echo " $STORAGE_HOST"

#
# Create the secrets with the credentials
#
echo [+] Creating a Kubernetes Secret with the database credentials

kubectl create secret generic database-credentials --from-literal=OWNCLOUD_DB_USERNAME=$DB_USERNAME --from-literal=OWNCLOUD_DB_PASSWORD=$DB_PASSWORD

#
# Create a ConfigMap with the environment variables
#
echo [+] Creating a ConfigMap with the environment variables

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: environment-variables
  namespace: default
data:
  OWNCLOUD_DB_TYPE: mysql
  OWNCLOUD_DB_HOST: $DB_HOST
  OWNCLOUD_DB_NAME: $DB_NAME
  OWNCLOUD_DB_PREFIX: $DB_PREFIX
  OWNCLOUD_MYSQL_UTF8MB4: "true"
EOF

#
# Create the deployment on GKE
#
echo [+] Creating the deployment on GKE

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $NAME-deployment
  labels:
    app: $NAME
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $NAME
  template:
    metadata:
      labels:
        app: $NAME
    spec:
      volumes:
      - name: nfs-volume
        nfs:
          server: $STORAGE_HOST
          path: /$STORAGE_NAME
      containers:
      - name: $NAME
        image: $IMAGE
        ports:
        - containerPort: $CONTAINER_PORT
        volumeMounts:
        - name: nfs-volume
          mountPath: /mnt/data
        envFrom:
        - configMapRef:
            name: environment-variables
        - secretRef:
            name: database-credentials
EOF

#
# Expose the deployment to the internet
#
echo [+] Exposing the deployment to the internet on port 80

kubectl expose deployment $NAME-deployment --type=LoadBalancer --name=expose-$NAME --port=80 --target-port=$CONTAINER_PORT

#
# End of the script
#
echo [+] Done!


