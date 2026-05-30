#!/bin/bash
# AI 직원 시스템 전체 기동 스크립트

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/logs"
mkdir -p "$LOG"

source "$DIR/venv/bin/activate"

# config.py 존재 확인
if [ ! -f "$DIR/config.py" ]; then
    echo "❌ config.py 가 없습니다. config.example.py 를 복사 후 설정하세요."
    echo "   cp $DIR/config.example.py $DIR/config.py"
    exit 1
fi

# 모델 파일 확인
MODEL=$(python3 -c "from config import MODEL_MAIN; import os; print(os.path.expanduser(MODEL_MAIN))")
if [ ! -f "$MODEL" ]; then
    echo "❌ 모델 파일을 찾을 수 없습니다: $MODEL"
    echo "   setup.sh 를 먼저 실행하거나 config.py 의 MODEL_MAIN 을 확인하세요."
    exit 1
fi

echo "🚀 AI 직원 시스템 기동 중..."
echo "   모델: $MODEL"

# llama-server 바이너리 탐지
# (sudo install 본은 rpath 누락 버그가 있어 빌드 폴더 바이너리를 우선 사용)
if [ -x "$HOME/llama.cpp/build/bin/llama-server" ]; then
    LLAMA_BIN="$HOME/llama.cpp/build/bin/llama-server"
else
    LLAMA_BIN="llama-server"
fi
# dylib 검색 경로 보강
export DYLD_LIBRARY_PATH="$HOME/llama.cpp/build/bin:/usr/local/lib:$DYLD_LIBRARY_PATH"
echo "   바이너리: $LLAMA_BIN"

# ① LLM 서버 (Metal GPU 활용)
# 혹시 남아있는 좀비 서버 정리 (포트 충돌 방지)
pkill -9 -f "llama-server" 2>/dev/null || true
sleep 1

# CPU 모드로 실행한다.
# 이유: Intel Mac + AMD Radeon Pro 5700 XT(RDNA1) 조합은 llama.cpp Metal
# 백엔드에서 (1) 깨진 출력(gibberish) (2) 0.8 t/s 극저속 버그가 있다.
# (llama.cpp Issue #19431, #20104). i9 10코어 CPU 가 GPU 보다 ~25배 빠르다.
CPU_CORES="$(sysctl -n hw.physicalcpu)"
"$LLAMA_BIN" \
    -m "$MODEL" \
    -ngl 0 \
    -t "$CPU_CORES" \
    -c 8192 \
    -np 2 \
    --host 0.0.0.0 \
    --port 11434 \
    --metrics \
    > "$LOG/llm.log" 2>&1 &
LLM_PID=$!
echo "  [1/3] LLM 서버 시작 (PID $LLM_PID, CPU ${CPU_CORES}코어)"

# LLM 서버 준비 대기
echo "  LLM 서버 준비 대기 중..."
for i in $(seq 1 30); do
    if curl -s http://localhost:11434/health > /dev/null 2>&1; then
        echo "  ✅ LLM 서버 준비 완료"
        break
    fi
    sleep 2
done

# ② 에이전트 네트워크 API 서버
python "$DIR/agent_network.py" \
    > "$LOG/network.log" 2>&1 &
NET_PID=$!
echo "  [2/3] 네트워크 서버 시작 (PID $NET_PID)"

# ③ 텔레그램 봇
python "$DIR/telegram_bot.py" \
    > "$LOG/telegram.log" 2>&1 &
TG_PID=$!
echo "  [3/3] 텔레그램 봇 시작 (PID $TG_PID)"

# PID 저장
echo "$LLM_PID" > "$DIR/logs/llm.pid"
echo "$NET_PID" > "$DIR/logs/network.pid"
echo "$TG_PID"  > "$DIR/logs/telegram.pid"

echo ""
echo "✅ AI 직원 시스템 가동 완료"
echo "   LLM 서버:  http://localhost:11434"
echo "   Agent API: http://localhost:8000"
echo "   로그:      $LOG/"
echo ""
echo "종료: ./stop.sh"

wait
