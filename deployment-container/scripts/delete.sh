export ARM_USE_MSI=true
export ARM_CLIENT_ID=$ADE_CLIENT_ID
export ARM_TENANT_ID=$ADE_TENANT_ID
export ARM_SUBSCRIPTION_ID=$ADE_SUBSCRIPTION_ID

export TF_VAR_resource_group_name=$ADE_RESOURCE_GROUP_NAME
export TF_VAR_ade_env_name=$ADE_ENVIRONMENT_NAME
export TF_VAR_env_name=$ADE_ENVIRONMENT_NAME
export TF_VAR_ade_subscription=$ADE_SUBSCRIPTION_ID
export TF_VAR_ade_location=$ADE_ENVIRONMENT_LOCATION
export TF_VAR_ade_environment_type=$ADE_ENVIRONMENT_TYPE
# we can add other ENV from https://learn.microsoft.com/en-us/azure/deployment-environments/reference-deployment-environment-variables

terraform init
terraform plan -no-color -compact-warnings -destroy -refresh=true -lock=true -state=$EnvironmentState -out=$EnvironmentPlan -var-file="$EnvironmentVars"
terraform apply -no-color -compact-warnings -auto-approve -lock=true -state=$EnvironmentState $EnvironmentPlan

tfOutputs=$(terraform output -state=$EnvironmentState -json)
# Convert Terraform output format to ADE format.
tfOutputs=$(jq 'walk(if type == "object" then 
            if .type == "bool" then .type = "boolean" 
            elif .type == "list" then .type = "array" 
            elif .type == "map" then .type = "object" 
            elif .type == "set" then .type = "array" 
            elif (.type | type) == "array" then 
                if .type[0] == "tuple" then .type = "array" 
                elif .type[0] == "object" then .type = "object" 
                elif .type[0] == "set" then .type = "array" 
                else . 
                end 
            else . 
            end 
        else . 
        end)' <<< "$tfOutputs")

echo "{\"outputs\": $tfOutputs}" > $ADE_OUTPUTS