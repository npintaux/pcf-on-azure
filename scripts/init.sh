#!/bin/bash

echo
echo "This script is preparing the configuration file you will need to customize to install PCF on Azure using Terraform."
echo "Prerequisite: be logged into your Azure account. If you have not done so, please run the following commands first:"
echo "    az login"
echo "    az account list (to see which subscriptions are available)"
echo "    az account set --subscription <subscription_id> (to select the correct one)"
echo
echo
read -p "Please input your domain name: " AZURE_DOMAIN_SUFFIX
read -p "Please input the name of the resource group for PCF (lower case): " PCF_RG 
read -p "Please input your PivNet token: " PIVNET_TOKEN
read -p "Please input a password for OpsManager: " OPSMAN_ADMIN_PWD

echo "Please select the region to deploy PCF: " 
select AZURE_REGION in "Australia East" "Australia Southeast" "Brazil South" "Canada Central" "Canada East" "Central India" "Central US" "East Asia" "East US" "East US 2" "France Central" "Japan East" "Japan West" "Korea Central" "Korea South" "North Central US" "North Europe" "South Central US" "South India" "Southeast Asia" "UK South" "UK West" "West Central US" "West Europe" "West India" "West US" "West US 2"
do
    break
done
read -p "Please input the URI of OpsManager VHD: " OPSMAN_URI

echo "Please select which product to install: "
select PAS_OR_PKS in "PAS" "PKS"
do
    break
done

AZURE_SUBSCRIPTION_ID=`az account show --query id`
AZURE_TENANT_ID=`az account show --query tenantId`
AZURE_ACCOUNT_NAME=`az account show --query name`
AZURE_APP_IDENTIFIER_URI=$(printf "http://BOSHAzureCPI-%s-%s" "${AZURE_ACCOUNT_NAME//\"/}" "$RANDOM")
AZURE_SP_PWD=$(printf "Pivotal-%s-%s" "${PCF_RG}" "$RANDOM")

IS_APP_PRESENT=`az ad app list --identifier-uri $AZURE_APP_IDENTIFIER_URI`

    
echo "Initializing the Azure AD Application"
AZURE_CLIENT_SECRET="$AZURE_SP_PWD"
AZURE_CLIENT_ID=`az ad app create --display-name "Service Principal for BOSH" \
	--password $AZURE_SP_PWD --homepage "http://BOSHAzureCPI" \
        --identifier-uris $AZURE_APP_IDENTIFIER_URI --query "appId"`

echo
echo "Initializing the Azure Service Principal"
AZURE_SP_OBJECT_ID=`az ad sp create --id $(printf "%s" "${AZURE_CLIENT_ID//\"/}") --query "objectId"`

echo "Waiting for 60 seconds to let the Service Principal propagate in Azure Active Directory..."
sleep 60 
    
AZURE_SCOPE=$(printf "/subscriptions/%s" "${AZURE_SUBSCRIPTION_ID//\"/}")
echo "Azure Scope: $AZURE_SCOPE"
az role assignment create --assignee-object-id $(printf "%s" "${AZURE_SP_OBJECT_ID//\"/}") \
        --role Contributor --scope $AZURE_SCOPE

echo
echo "Registering subscription with Storage service"
az provider register --namespace Microsoft.Storage

echo "Registering subscription with Network service"
az provider register --namespace Microsoft.Network

echo "Registering subscription with Compute service"
az provider register --namespace Microsoft.Compute

echo "Initializing Terraform variable files"
cat > "terraform.tfvars" <<-EOF
# Azure specific variables
subscription_id=$AZURE_SUBSCRIPTION_ID
tenant_id=$AZURE_TENANT_ID
client_id=$AZURE_CLIENT_ID
client_secret="${AZURE_CLIENT_SECRET}"

env_name="${PCF_RG}"
env_short_name="${PCF_RG}"
location="${AZURE_REGION}"
dns_suffix="${AZURE_DOMAIN_SUFFIX}"
vm_admin_username="admin"
ops_manager_image_uri="${OPSMAN_URI}"
EOF

cp terraform.tfvars environment.cfg

echo "Initializing environment file..."
cat > "environment.cfg" <<-EOF
# PCF specific variables
PCF_PIVNET_UAA_TOKEN="${PIVNET_TOKEN}"
PCF_DOMAIN_NAME="${AZURE_DOMAIN_SUFFIX}"
PCF_SUBDOMAIN_NAME="${PCF_RG}"
PCF_OPSMAN_ADMIN_PASSWD="${OPSMAN_ADMIN_PWD}"
PCF_REGION="${AZURE_REGION}"
PCF_OPSMAN_FQDN=pcf.${PCF_RG}.${AZURE_DOMAIN_SUFFIX}

# Product versions - to be replaced with questions and queries to PivNet
OPSMAN_VERSION="2.4.1"
PAS_VERSION="2.4.1"
PKS_VERSION="1.3"

# OM CLI Specifics
OM_TARGET=pcf.${PCF_RG}.${AZURE_DOMAIN_SUFFIX}
OM_USERNAME=admin
OM_PASSWORD="${OPSMAN_ADMIN_PWD}"
OM_DECRYPTION_PASSPHRASE="one two three four five"
EOF

# Copy the terraform.tfvars file as an environment file as well
# This will be used when installing Opsman
cp terraform.tfvars ../config
cp environment.cfg ~/.env
mv environment.cfg ../config

# Download the Terraform files
./init-opsman.sh

# Trigger the install of PAS or PKS
if [ "$PAS_OR_PKS" = "PAS" ]; then
    ./init-pas.sh
else
    ./init-pks.sh
fi