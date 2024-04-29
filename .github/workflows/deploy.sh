RED="\e[31m"
GREEN="\e[32m"
ORANGE="\e[95m"
ENDCOLOR="\e[0m" 

# create RG
echo "Creating RG"
az group create -n "${{ github.event.inputs.RESOURCE_GROUP }}" -l ${{ github.event.inputs.LOCATION }} -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# create keyvault & inject PAT as secret

echo "Creating keyvault"
kvName=$(az keyvault list-deleted --query "[?contains(name, '${{ github.event.inputs.KV_NAME }}')].name" -o tsv)
case "$kvName" in 
"${{ github.event.inputs.KV_NAME }}" ) echo 'KV name already exists. Trying to purge'
az keyvault purge --name "${{ github.event.inputs.KV_NAME }}";;
*) ;;
esac

az keyvault create -n "${{ github.event.inputs.KV_NAME }}" -l ${{ github.event.inputs.LOCATION }} -g "${{ github.event.inputs.RESOURCE_GROUP }}"  -o none
export GHPAT="${{ github.event.inputs.PAT_TOKEN }}"
if [ -z "$GHPAT" ]
then
    echo "create secret using PAT given in secrets"
    az keyvault secret set --vault-name "${{ github.event.inputs.KV_NAME }}" --name GHPAT --value "${{ secrets.PAT_TOKEN }}" -o none
else
    echo "create secret using PAT given in input"
    az keyvault secret set --vault-name "${{ github.event.inputs.KV_NAME }}" --name GHPAT --value "${{ github.event.inputs.PAT_TOKEN }}"  -o none
fi
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# create dev environnement
echo "Creating dev center"
az devcenter admin devcenter create --location "${{ github.event.inputs.LOCATION }}" --name "${{ github.event.inputs.DEVCENTER_NAME }}" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# enable system identity on DevCenter
echo "Enabling managed identity"
az devcenter admin devcenter update -n "${{ github.event.inputs.DEVCENTER_NAME }}" --identity-type SystemAssigned --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# retrieving DevCenter identity
echo "Retrieving managed identity"
OID=$(az ad sp list --display-name "${{ github.event.inputs.DEVCENTER_NAME }}" --query [].id -o tsv)
printf "${ORANGE}$OID${ENDCOLOR}\n"
sleep 30 # wait for replication
echo -e "Creating KV policy"
az keyvault set-policy -n "${{ github.event.inputs.KV_NAME }}" --secret-permissions get --object-id $OID -g ${{ github.event.inputs.RESOURCE_GROUP }} -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"


# retrieve DevCenterId & principalID
echo "Retrieving IDs"
DEVCENTER_ID=$(az devcenter admin devcenter show --name "${{ github.event.inputs.DEVCENTER_NAME }}" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" --query=id -o tsv)
DEV_CENTER_CLIENT_ID=$(az devcenter admin devcenter show \
--name "${{ github.event.inputs.DEVCENTER_NAME }}" \
--resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" \
--query identity.principalId -o tsv)
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# Custom Image
export IMAGE_BUILDER_GALLERY_NAME="imagebuildergallery"
echo -e "Creating Azure Compute Gallery $IMAGE_BUILDER_GALLERY_NAME in $LOCATION"
az sig create \
--resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" \
--gallery-name $IMAGE_BUILDER_GALLERY_NAME \
--location "${{ github.event.inputs.LOCATION }}" \
-o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

echo "Let's assign the Contributor role to the Dev Center for the gallery"
az role assignment create \
--role "Contributor" \
--assignee $DEV_CENTER_CLIENT_ID \
--scope $(az sig show --gallery-name $IMAGE_BUILDER_GALLERY_NAME \
--resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" --query id -o tsv) \
-o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

echo "Then you can associate the gallery with the Dev Center"
az devcenter admin gallery create \
--name $IMAGE_BUILDER_GALLERY_NAME \
--gallery-resource-id $(az sig show --gallery-name $IMAGE_BUILDER_GALLERY_NAME --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" --query id -o tsv) \
--dev-center "${{ github.event.inputs.DEVCENTER_NAME }}" \
--resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" \
-o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

echo -e "Creating image definition vscodeImage in Azure Compute Gallery $IMAGE_BUILDER_GALLERY_NAME"

az sig image-definition create \
--resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" \
--gallery-name $IMAGE_BUILDER_GALLERY_NAME \
--gallery-image-definition "vscodeImage" \
--os-type "Windows" \
--os-state "Generalized" \
--publisher "lgmorand" \
--offer "vscodebox" \
--sku "1-0-0" \
--hyper-v-generation "V2" \
--features "SecurityType=TrustedLaunch" \
-o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

IMAGE_BUILDER_IDENTITY="image-builder-identity"
echo -e "Creating Azure Image Builder identity $IMAGE_BUILDER_IDENTITY"

IDENTITY_CLIENT_ID=$(az identity create \
--name $IMAGE_BUILDER_IDENTITY \
--resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" \
--query clientId -o tsv)
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

echo -e "Wait 30 seconds for the identity to be created 🕒"
sleep 30

echo -e "Assigning role to Azure Image Builder identity $IMAGE_BUILDER_IDENTITY"

roleId=$(az role definition list --query "[?contains(roleName, 'Azure Image Builder Service Image Creation Role')].id" -o tsv)
echo $roleId
if [ -z "$roleId" ]
then
az role definition create -o none --role-definition @- <<-EOF
{
    "Name": "Azure Image Builder Service Image Creation Role",
    "IsCustom": true,
    "Description": "Image Builder access to create resources for the image build, you should delete or split out as appropriate",
    "Actions": [
        "Microsoft.Compute/galleries/read",
        "Microsoft.Compute/galleries/images/read",
        "Microsoft.Compute/galleries/images/versions/read",
        "Microsoft.Compute/galleries/images/versions/write",

        "Microsoft.Compute/images/write",
        "Microsoft.Compute/images/read",
        "Microsoft.Compute/images/delete"
    ],
    "NotActions": [
    
    ],
    "AssignableScopes": [
        "/subscriptions/${{ vars.SUBSCRIPTION_ID }}"
    ]
    }
EOF
else
echo "Role already exists, no need to create"
fi

printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

echo -e "Check the custom role was created successfully 🎉"

az role definition list --custom-role-only -o table 

echo -e "Assign the custom role to the identity $IMAGE_BUILDER_IDENTITY"

az role assignment create \
--role "Azure Image Builder Service Image Creation Role" \
--assignee $IDENTITY_CLIENT_ID \
--scope /subscriptions/${{ vars.SUBSCRIPTION_ID }}/resourceGroups/${{ github.event.inputs.RESOURCE_GROUP }} -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

echo -e "Check the role was assigned successfully ✅"
az role assignment list --assignee $IDENTITY_CLIENT_ID --all -o table

IDENTITY_ID=$(az identity show --name $IMAGE_BUILDER_IDENTITY --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" --query id -o tsv)
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# Create environment types
echo "Creating environments"
az devcenter admin environment-type create --dev-center-name "${{ github.event.inputs.DEVCENTER_NAME }}" --name "PROD" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" -o none
az devcenter admin environment-type create --dev-center-name "${{ github.event.inputs.DEVCENTER_NAME }}" --name "TEST" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" -o none
az devcenter admin environment-type create --dev-center-name "${{ github.event.inputs.DEVCENTER_NAME }}" --name "DEV" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# create a project
echo "Creating projects"
az devcenter admin project create --location "${{ github.event.inputs.LOCATION }}" --description "This is my first project." --dev-center-id "$DEVCENTER_ID" --name "${{ github.event.inputs.PROJECT_NAME }}" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" --max-dev-boxes-per-user "3" -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# create a DevBox
echo "Creating dev box"
az devcenter admin devbox-definition create --location "${{ github.event.inputs.LOCATION }}" --image-reference id="/subscriptions/${{ vars.SUBSCRIPTION_ID }}/resourceGroups/${{ github.event.inputs.RESOURCE_GROUP }}/providers/Microsoft.DevCenter/devcenters/${{ github.event.inputs.DEVCENTER_NAME }}/galleries/default/images/microsoftvisualstudio_visualstudioplustools_vs-2022-ent-general-win11-m365-gen2" --os-storage-type "ssd_256gb" --sku name="general_i_8c32gb256ssd_v2" --name "WebDevBox" --dev-center-name "${{ github.event.inputs.DEVCENTER_NAME }}" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" -o none
az devcenter admin devbox-definition create --location "${{ github.event.inputs.LOCATION }}" --image-reference id="/subscriptions/${{ vars.SUBSCRIPTION_ID }}/resourceGroups/${{ github.event.inputs.RESOURCE_GROUP }}/providers/Microsoft.DevCenter/devcenters/${{ github.event.inputs.DEVCENTER_NAME }}/galleries/default/images/microsoftvisualstudio_visualstudioplustools_vs-2022-ent-general-win11-m365-gen2" --os-storage-type "ssd_512gb" --sku name="general_i_32c128gb512ssd_v2" --name "SuperPowerfulDevBox" --dev-center-name "${{ github.event.inputs.DEVCENTER_NAME }}" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# create a catalog
echo "Creating catalog"
SECRETID=$(az keyvault secret show --vault-name ${{ github.event.inputs.KV_NAME }} --name GHPAT --query id -o tsv)
printf "${ORANGE} $SECRETID ${ENDCOLOR}\n"
REPO_URL="https://github.com/lgmorand/azure-ade-devbox.git"
az devcenter admin catalog create --git-hub path="/catalog" branch="main" secret-identifier=$SECRETID uri=$REPO_URL -n "EnvCatalog" -d "${{ github.event.inputs.DEVCENTER_NAME }}" -g ${{ github.event.inputs.RESOURCE_GROUP }} -o none
REPO_URL="https://github.com/microsoft/devcenter-catalog.git"
az devcenter admin catalog create --git-hub path="/Tasks" branch="main" secret-identifier=$SECRETID uri=$REPO_URL -n "QuickStart" -d "${{ github.event.inputs.DEVCENTER_NAME }}" -g ${{ github.event.inputs.RESOURCE_GROUP }} -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

# creating pools
echo "Creating pools"
az devcenter admin pool create --location "${{ github.event.inputs.LOCATION }}" --devbox-definition-name "WebDevBox" --pool-name "DevPool" --project-name "${{ github.event.inputs.PROJECT_NAME }}" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" --local-administrator "Enabled" --virtual-network-type "Managed" --managed-virtual-network-regions "westeurope" -o none
az devcenter admin pool create --location "${{ github.event.inputs.LOCATION }}" --devbox-definition-name "SuperPowerfulDevBox" --pool-name "DevPoolPowerFull" --project-name "${{ github.event.inputs.PROJECT_NAME }}" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" --local-administrator "Enabled" --virtual-network-type "Managed" --managed-virtual-network-regions "westeurope" -o none
printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"

echo "giving access to the user"
ENTRA_ID_USER_ID=$(az ad user show --id ${{ github.event.inputs.DEMO_USER }} --query id -o tsv)
az role assignment create \
--role "DevCenter Dev Box User" \
--assignee $ENTRA_ID_USER_ID \
--scope $(az devcenter admin project show --name "${{ github.event.inputs.PROJECT_NAME }}" --resource-group "${{ github.event.inputs.RESOURCE_GROUP }}" --query id -o tsv) -o none

printf $"${GREEN}\u2714 Success ${ENDCOLOR}\n\n"


echo "::notice::You can now access your DevCenter at https://devportal.microsoft.com/"


