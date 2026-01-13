# run-vllm-dev.ps1
# Launch a vLLM dev container with Podman, mounting your local fork and a persistent model cache.
# Workaround: install NumPy and do a normal `pip install .` instead of editable mode to avoid setuptools_scm timeouts.

# === Configuration ===
$Network          = "llm-net"
$ContainerName    = "vllm-dev"
$PortMappingAPI   = "127.0.0.1:8000:8000"
$PortMappingSSH   = "2222:22"
$Gpus             = "--gpus all"
$VolumeVLLM       = 'C:\sources\github\vllm:/workspace/vllm'       # your fork
$ModelCacheVolume = 'C:\models\huggingface:/root/.cache/huggingface'  # persistent HF cache
$EnvPytorchCuda   = 'PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True'
$EnvToken        = 'HUGGINGFACE_HUB_TOKEN=your_huggingface_token_here' # Replace with your actual Hugging Face token.
$EnvVLLM          = 'VLLM_USE_v1=1'
$EnvDisableFlash  = 'VLLM_DISABLE_FLASH_ATTN=1'
$ImageName        = "vllm/vllm-openai:latest"
$Entrypoint       = "--entrypoint /bin/bash"

# === Inner shell commands ===
#  - install SSH, sudo, build tools
#  - create user1 and set password
#  - install NumPy
#  - install vLLM from source (pip install .)
#  - test vLLM
$InnerCommand = @"
export DEBIAN_FRONTEND=noninteractive && \
apt-get update && \
apt-get install -y openssh-server sudo cmake ninja-build && \
useradd -m user1 && \
echo 'user1:zobizobi' | chpasswd && \
mkdir -p /var/run/sshd && \
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \
echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config && \
service ssh start && \
git clone https://github.com/ohmybash/oh-my-bash.git ~/.oh-my-bash && \
cp ~/.oh-my-bash/templates/bashrc.osh-template ~/.bashrc && \
cd /workspace/vllm && \
pip install numpy setuptools_scm && \
pip install . && \
echo 'import vllm; print(vllm.__version__)' > test_vllm.py && \
python3 test_vllm.py --model tflsxyy/DeepSeek-V3-4bit-4layers
"@

# Strip any Windows CR characters
$InnerCommand = $InnerCommand -replace "`r",""

# === Build and run the Podman command ===
$PodmanCmd = @(
  "podman run -d",
  "--network $Network",
  "--name $ContainerName",
  "-p $PortMappingAPI",
  "-p $PortMappingSSH",
  "$Gpus",
  "-v `"$VolumeVLLM`"",
  "-v `"$ModelCacheVolume`"",
  "-e `"$EnvPytorchCuda`"",
  "-e `"$EnvToken`"",
  "-e `"$EnvVLLM`"",
  "-e `"$EnvDisableFlash`"",
  "$Entrypoint",
  "$ImageName",
  "-c `"$InnerCommand`""
) -join " "

Write-Host "`n▶ Executing Podman command:`n$PodmanCmd`n"
Invoke-Expression $PodmanCmd