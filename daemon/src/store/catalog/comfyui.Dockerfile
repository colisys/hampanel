FROM docker.io/library/python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 libgl1 git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone https://github.com/Comfy-Org/ComfyUI.git . && git checkout a277b5bf213e8a44fa34817b7770b54f86ef4cea
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch torchvision torchaudio && pip install --no-cache-dir -r requirements.txt
CMD ["python", "main.py", "--cpu", "--listen", "0.0.0.0", "--port", "8188"]
