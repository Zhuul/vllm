# run-vllm-dev.ps1
# This script launches your vLLM development container using Podman.
# It mounts your local fork from "C:\sources\github\vllm" and a persistent model cache at "C:\models".
# The inner command creates a user named "user1", sets its password, and performs several setup tasks.
# Ensure Podman (and Podman Machine) is properly configured on your Windows system.

# Configuration variables
$Network         = "llm-net"
$ContainerName   = "vllm-dev"
$PortMapping1    = "127.0.0.1:8000:8000"
$PortMapping2    = "2222:22"
$Gpus            = "--gpus all"
$VolumeMapping   = 'C:\sources\github\vllm:/workspace/vllm'   # Adjust your local source path as needed.
$ModelCacheVolume= 'C:\models\huggingface:/root/.cache/huggingface'        # Persistent cache for model files.
$EnvPytorchCuda  = 'PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True'
$EnvToken        = 'HUGGINGFACE_HUB_TOKEN=your_huggingface_token_here'  # Replace with your actual Hugging Face token.
$EnvVLLM         = 'VLLM_USE_v1=1'
# Disable optional flash attention CUDA modules to avoid build issues
$EnvDisableFlash = 'VLLM_DISABLE_FLASH_ATTN=1'
$ImageName       = "vllm/vllm-openai:latest"  # Change if you built your own image.
$Entrypoint      = "--entrypoint /bin/bash"

# Define the inner command as a here-string.
# The command now:
#  - Sets DEBIAN_FRONTEND noninteractive,
#  - Creates the user "user1" (if it does not exist),
#  - Sets the password for user1,
#  - Installs necessary packages,
#  - Sets up SSH server configuration,
#  - Clones an oh-my-bash configuration,
#  - Installs vllm from the mounted source, and
#  - Runs a test script using python3.
$InnerCommand = @"
apt-get update && \
apt-get install -y openssh-server sudo cmake ninja-build && \
export DEBIAN_FRONTEND=noninteractive && \
useradd -m user1 && \
echo 'user1:zobizobi' | chpasswd && \
mkdir -p /var/run/sshd && \
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \
echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config && \
service ssh start && \
git clone https://github.com/ohmybash/oh-my-bash.git ~/.oh-my-bash && \
cp ~/.oh-my-bash/templates/bashrc.osh-template ~/.bashrc && \
cd /workspace/vllm && \
pip install -e . && \
echo 'import vllm; print(vllm.__version__)' > test_vllm.py && \
python3 test_vllm.py --model tflsxyy/DeepSeek-V3-4bit-4layers
"@

# Remove Windows carriage-return characters that might be present.
$InnerCommand = $InnerCommand -replace "`r", ""

# Build the complete Podman command.
# We pass -c "<InnerCommand>" right after the image name.
$PodmanCommand = "podman run -d --network $Network --name $ContainerName -p $PortMapping1 -p $PortMapping2 $Gpus -v `"$VolumeMapping`" -v `"$ModelCacheVolume`" -e `"$EnvPytorchCuda`" -e `"$EnvToken`" -e `"$EnvVLLM`" -e `"$EnvDisableFlash`" $Entrypoint $ImageName -c `"$InnerCommand`""

# Display the final command for verification.
Write-Host "Executing the following Podman command:`n$PodmanCommand`n"

# Execute the Podman command.
Invoke-Expression $PodmanCommand