@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "LOG=%~dp0install_log.txt"
echo FitMe local GPU install %DATE% %TIME% > "%LOG%"
echo ================================================================
echo FitMe AI - install FASHN VTON 1.5 on your NVIDIA GPU
echo Downloads about 5 GB (PyTorch CUDA + FASHN weights). Takes 10-30 min.
echo Progress is written to install_log.txt
echo ================================================================

rem ---- find real Python 3.10+ (skip the Microsoft Store stub) ----
set "PY="
py -3.12 -c "import sys" >nul 2>&1 && set "PY=py -3.12"
if not defined PY py -3.11 -c "import sys" >nul 2>&1 && set "PY=py -3.11"
if not defined PY python -c "import sys; assert sys.version_info >= (3, 10)" >nul 2>&1 && set "PY=python"
if not defined PY if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" set "PY="%LOCALAPPDATA%\Programs\Python\Python312\python.exe""
if not defined PY (
  echo ERROR: Python 3.10+ not found. Install Python 3.12 from python.org with "Add python.exe to PATH". >> "%LOG%"
  type "%LOG%"
  pause
  exit /b 1
)
echo Python: %PY% >> "%LOG%"
%PY% --version >> "%LOG%" 2>&1

echo ===== NVIDIA driver ===== >> "%LOG%"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv >> "%LOG%" 2>&1
if errorlevel 1 (
  echo ERROR: nvidia-smi not found - install the NVIDIA driver first. >> "%LOG%"
  type "%LOG%"
  pause
  exit /b 1
)

echo ===== GPU server venv ===== >> "%LOG%"
echo [1/4] GPU server environment...
if not exist "gpu_server\.venv\Scripts\python.exe" %PY% -m venv gpu_server\.venv >> "%LOG%" 2>&1
set "GPY=%~dp0gpu_server\.venv\Scripts\python.exe"
"%GPY%" -m pip install --upgrade pip >> "%LOG%" 2>&1

echo [2/4] PyTorch with CUDA (about 3 GB)...
echo ===== torch cu128 ===== >> "%LOG%"
"%GPY%" -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128 >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo [3/4] FASHN VTON 1.5 and server packages...
echo ===== fashn-vton ===== >> "%LOG%"
"%GPY%" -m pip install "fashn-vton @ git+https://github.com/fashn-AI/fashn-vton-1.5.git" fastapi "uvicorn[standard]" python-multipart huggingface_hub >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
"%GPY%" -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else '-')" >> "%LOG%" 2>&1

echo ===== weights ===== >> "%LOG%"
"%GPY%" -c "import os; from huggingface_hub import hf_hub_download as d; w=r'%~dp0gpu_server\weights'; d('fashn-ai/fashn-vton-1.5','model.safetensors',local_dir=w); [d('fashn-ai/DWPose',f,local_dir=os.path.join(w,'dwpose')) for f in ('yolox_l.onnx','dw-ll_ucoco_384.onnx')]; print('weights OK')" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo [4/4] Backend environment...
echo ===== backend venv ===== >> "%LOG%"
if not exist "backend\.venv\Scripts\python.exe" %PY% -m venv backend\.venv >> "%LOG%" 2>&1
"%~dp0backend\.venv\Scripts\python.exe" -m pip install --upgrade pip >> "%LOG%" 2>&1
"%~dp0backend\.venv\Scripts\python.exe" -m pip install -r backend\requirements.txt >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
"%~dp0backend\.venv\Scripts\python.exe" -m pip install -r backend\requirements-cutout.txt >> "%LOG%" 2>&1 || echo rembg skipped >> "%LOG%"

echo ===== INSTALL OK ===== >> "%LOG%"
echo.
echo Done! Now run START_LOCAL_GPU.bat
pause
exit /b 0

:fail
echo ===== INSTALL FAILED ===== >> "%LOG%"
echo.
echo Install failed - see install_log.txt
pause
exit /b 1
