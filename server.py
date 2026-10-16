import io
import os
import json
import asyncio
import logging

from flask import Flask, request, Response
import edge_tts

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("tts-server")

TOKEN = os.environ.get("TTS_TOKEN", "").strip()
PORT = int(os.environ.get("PORT", "8080"))

# 发音人目录：完整沿用 legado_NG 内置「Next Edge TTS」的 39 个音色（id/name/gender/profile/styles/roles）。
# 与内置的唯一区别：请求发往你自己的服务器，而非内置写死的第三方 IP（5.45.99.149 / 146.56.188.115）。
# styles = 该音色支持的 Edge 情绪风格；roles = 支持的角色切换。
VOICES = [
    {"id": "zh-CN-XiaoxiaoNeural", "name": "晓晓", "gender": "female", "profile": "少女感-温柔旁白",
     "styles": ["affectionate", "angry", "assistant", "calm", "chat", "chat-casual", "cheerful", "customerservice", "disgruntled", "excited", "fearful", "friendly", "gentle", "lyrical", "newscast", "poetry-reading", "sad", "serious", "sorry", "whispering"], "roles": []},
    {"id": "zh-CN-XiaoyiNeural", "name": "晓亦", "gender": "female", "profile": "少女-活泼甜亮",
     "styles": ["affectionate", "angry", "cheerful", "disgruntled", "embarrassed", "fearful", "gentle", "sad", "serious"], "roles": []},
    {"id": "zh-CN-XiaochenNeural", "name": "晓辰", "gender": "female", "profile": "女青年-自然柔和",
     "styles": ["livecommercial"], "roles": []},
    {"id": "zh-CN-XiaohanNeural", "name": "晓涵", "gender": "female", "profile": "少女-高亮温柔",
     "styles": ["affectionate", "angry", "calm", "cheerful", "disgruntled", "embarrassed", "fearful", "gentle", "sad", "serious"], "roles": []},
    {"id": "zh-CN-XiaomengNeural", "name": "晓梦", "gender": "female", "profile": "少女-轻柔聊天",
     "styles": ["chat"], "roles": []},
    {"id": "zh-CN-XiaomoNeural", "name": "晓墨", "gender": "female", "profile": "少女-多角色温柔",
     "styles": ["affectionate", "angry", "calm", "cheerful", "depressed", "disgruntled", "embarrassed", "envious", "fearful", "gentle", "sad", "serious"], "roles": ["Boy", "Girl", "OlderAdultFemale", "OlderAdultMale", "SeniorFemale", "SeniorMale", "YoungAdultFemale", "YoungAdultMale"]},
    {"id": "zh-CN-XiaoqiuNeural", "name": "晓秋", "gender": "female", "profile": "成熟女声-高亮硬朗", "styles": [], "roles": []},
    {"id": "zh-CN-XiaorouNeural", "name": "晓柔", "gender": "female", "profile": "少女-清甜", "styles": [], "roles": []},
    {"id": "zh-CN-XiaoruiNeural", "name": "晓睿", "gender": "female", "profile": "少女-冷亮情绪",
     "styles": ["angry", "calm", "fearful", "sad"], "roles": []},
    {"id": "zh-CN-XiaoshuangNeural", "name": "晓双", "gender": "female", "profile": "女童/少女-稚嫩清亮",
     "styles": ["chat"], "roles": []},
    {"id": "zh-CN-XiaoyanNeural", "name": "晓颜", "gender": "female", "profile": "女青年-自然柔和", "styles": [], "roles": []},
    {"id": "zh-CN-XiaoyouNeural", "name": "晓悠", "gender": "female", "profile": "少女-高亮稚嫩", "styles": [], "roles": []},
    {"id": "zh-CN-XiaozhenNeural", "name": "晓甄", "gender": "female", "profile": "女青年-清亮情绪",
     "styles": ["angry", "cheerful", "disgruntled", "fearful", "sad", "serious"], "roles": []},
    {"id": "zh-CN-YunxiNeural", "name": "云希", "gender": "male", "profile": "青年男声-阳光叙事",
     "styles": ["angry", "assistant", "chat", "cheerful", "depressed", "disgruntled", "embarrassed", "fearful", "narration-relaxed", "newscast", "sad", "serious"], "roles": ["Boy", "Narrator", "YoungAdultMale"]},
    {"id": "zh-CN-YunjianNeural", "name": "云间", "gender": "male", "profile": "低沉男声-热血解说",
     "styles": ["angry", "cheerful", "depressed", "disgruntled", "documentary-narration", "narration-relaxed", "sad", "serious", "sports-commentary", "sports-commentary-excited"], "roles": []},
    {"id": "zh-CN-YunyangNeural", "name": "云扬", "gender": "male", "profile": "青年男声-专业播报",
     "styles": ["customerservice", "narration-professional", "newscast-casual"], "roles": []},
    {"id": "zh-CN-YunfengNeural", "name": "云枫", "gender": "male", "profile": "青年男声-清朗情绪",
     "styles": ["angry", "cheerful", "depressed", "disgruntled", "fearful", "sad", "serious"], "roles": []},
    {"id": "zh-CN-YunhaoNeural", "name": "云皓", "gender": "male", "profile": "低沉男声-活力广告",
     "styles": ["advertisement-upbeat"], "roles": []},
    {"id": "zh-CN-YunjieNeural", "name": "云杰", "gender": "male", "profile": "少年男声-温和", "styles": [], "roles": []},
    {"id": "zh-CN-YunxiaNeural", "name": "云夏", "gender": "male", "profile": "男童/少年-高亮稚嫩",
     "styles": ["angry", "calm", "cheerful", "fearful", "sad"], "roles": []},
    {"id": "zh-CN-YunyeNeural", "name": "云野", "gender": "male", "profile": "低沉大叔-多角色",
     "styles": ["angry", "calm", "cheerful", "disgruntled", "embarrassed", "fearful", "sad", "serious"], "roles": ["Boy", "Girl", "OlderAdultFemale", "OlderAdultMale", "SeniorFemale", "SeniorMale", "YoungAdultFemale", "YoungAdultMale"]},
    {"id": "zh-CN-YunzeNeural", "name": "云泽", "gender": "male", "profile": "低沉长辈-纪录片",
     "styles": ["angry", "calm", "cheerful", "depressed", "disgruntled", "documentary-narration", "fearful", "sad", "serious"], "roles": ["OlderAdultMale", "SeniorMale"]},
    {"id": "zh-CN-XiaoxiaoDialectsNeural", "name": "晓晓DIA", "gender": "female", "profile": "女青年-方言清亮", "styles": [], "roles": []},
    {"id": "zh-CN-XiaoxiaoMultilingualNeural", "name": "晓晓MT", "gender": "female", "profile": "女青年-温柔多语",
     "styles": ["affectionate", "cheerful", "empathetic", "excited", "poetry-reading", "sorry", "story"], "roles": []},
    {"id": "zh-CN-XiaoyuMultilingualNeural", "name": "晓宇MT", "gender": "female", "profile": "少女-柔亮多语", "styles": [], "roles": []},
    {"id": "zh-CN-YunxiaoMultilingualNeural", "name": "云晓MT", "gender": "male", "profile": "青年男声-温和多语", "styles": [], "roles": []},
    {"id": "zh-CN-YunyiMultilingualNeural", "name": "云逸MT", "gender": "male", "profile": "青年男声-清朗多语", "styles": [], "roles": []},
    {"id": "zh-CN-YunfanMultilingualNeural", "name": "云帆MT", "gender": "male", "profile": "青年男声-明亮多语", "styles": [], "roles": []},
    {"id": "zh-CN-Xiaochen:DragonHDLatestNeural", "name": "晓辰HD", "gender": "female", "profile": "高清女声-自然柔和", "styles": [], "roles": []},
    {"id": "zh-CN-Yunfan:DragonHDLatestNeural", "name": "云帆HD", "gender": "male", "profile": "高清男声-清朗", "styles": [], "roles": []},
    {"id": "zh-CN-Xiaochen:DragonHDFlashLatestNeural", "name": "晓辰FHD", "gender": "female", "profile": "高清少女-明亮情绪",
     "styles": ["cheerful", "debating", "empathetic", "live-commercial", "poetry-reading", "sad", "sorry"], "roles": []},
    {"id": "zh-CN-Xiaoxiao:DragonHDFlashLatestNeural", "name": "晓晓FHD", "gender": "female", "profile": "高清少女-助手情绪",
     "styles": ["angry", "chat", "cheerful", "customer-service", "excited", "fearful", "sad", "voice-assistant"], "roles": []},
    {"id": "zh-CN-Xiaoxiao2:DragonHDFlashLatestNeural", "name": "潇潇FHD", "gender": "female", "profile": "高清女青年-细腻情绪",
     "styles": ["affectionate", "angry", "anxious", "cheerful", "curious", "disappointed", "empathetic", "encouraging", "excited", "fearful", "guilty", "lonely", "poetry-reading", "sad", "sentimental", "sorry", "story", "surprised", "tired", "whispering"], "roles": []},
    {"id": "zh-CN-Yunxiao:DragonHDFlashLatestNeural", "name": "云萧FHD", "gender": "male", "profile": "高清男声-清朗", "styles": [], "roles": []},
    {"id": "zh-CN-Yunye:DragonHDFlashLatestNeural", "name": "云野FHD", "gender": "male", "profile": "高清大叔-低沉", "styles": [], "roles": []},
    {"id": "zh-CN-Yunyi:DragonHDFlashLatestNeural", "name": "云逸FHD", "gender": "male", "profile": "高清男声-角色演绎",
     "styles": ["assassin", "captain", "cavalier", "game-narrator", "geomancer", "poet", "prince"], "roles": []},
    {"id": "zh-TW-HsiaoChenNeural", "name": "晓宸_繁", "gender": "female", "profile": "台配女青年-自然亲和", "styles": [], "roles": []},
    {"id": "zh-TW-HsiaoYuNeural", "name": "晓语_繁", "gender": "female", "profile": "台配成熟女声-明亮", "styles": [], "roles": []},
    {"id": "zh-TW-YunJheNeural", "name": "云喆_繁", "gender": "male", "profile": "台配男声-温和低沉", "styles": [], "roles": []},
]

app = Flask(__name__)

_STATUS_PAGE = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TTS-SERVER 状态</title>
<style>
 body{{font-family:system-ui,-apple-system,"Microsoft YaHei",sans-serif;background:#0f172a;color:#e2e8f0;
      display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}}
 .card{{background:#1e293b;border-radius:14px;padding:32px 40px;max-width:520px;width:92%;
      box-shadow:0 8px 30px rgba(0,0,0,.35)}}
 h1{{font-size:20px;margin:0 0 18px}}
 .ok{{color:#4ade80}} .warn{{color:#facc15}} .bad{{color:#f87171}}
 ul{{line-height:1.9;padding-left:20px;margin:14px 0}}
 a{{color:#60a5fa}} code{{background:#334155;padding:2px 6px;border-radius:4px;font-size:.9em}}
 .tip{{color:#94a3b8;font-size:13px;margin-top:16px}}
</style></head><body><div class="card">
<h1>🔊 TTS-SERVER</h1>
<ul>
 <li>{status_line}</li>
 <li>音色数量：<b>{voice_count}</b> 个（legado_NG 默认全量）</li>
 <li>Token：{token_line}</li>
 <li>试听测试：<a href="{tts_test}">点我播放一段测试语音</a></li>
 <li>音色清单：<a href="{voices_url}">/voices</a></li>
</ul>
<p class="tip">本服务为 legado_NG「自托管 Edge TTS」引擎专用 API，没有网页界面属正常现象。<br>
legado_NG 里『服务地址』填本页地址栏的完整 URL（含 ?token=...）。</p>
</div></body></html>"""


@app.route("/")
def index():
    given = request.args.get("token", "")
    if TOKEN and given and given != TOKEN:
        status_line = '<span class="bad">✗ Token 错误</span>——请核对服务地址里的 ?token=... 是否完整'
        token_line = '<span class="bad">校验失败</span>'
    elif TOKEN and not given:
        status_line = '<span class="warn">⚠ 服务运行中</span>，但你没带 token（legado_NG 调用时必须带）'
        token_line = '已启用（未提供）'
    else:
        status_line = '<span class="ok">✓ 服务运行中，一切正常</span>'
        token_line = '<span class="ok">校验通过</span>' if TOKEN else "未启用"

    voices_url = f"/voices?token={given}" if given else "/voices"
    tts_test = f"/tts?text=你好，自托管语音服务已就绪&token={given}" if given else "/tts?text=你好，自托管语音服务已就绪"
    body = _STATUS_PAGE.format(status_line=status_line, voice_count=len(VOICES),
                               token_line=token_line, voices_url=voices_url, tts_test=tts_test)
    return Response(body, mimetype="text/html")


def _authorized():
    if not TOKEN:
        return True
    return request.args.get("token", "") == TOKEN


def _clamp(v, lo, hi, default):
    try:
        v = int(float(v))
    except (TypeError, ValueError):
        v = default
    return max(lo, min(hi, v))


def _map_units(speed, pitch, volume):
    """0-100 习惯值 → Edge SSML 单位。"""
    rate = (speed - 50) * 1.5      # -75% ~ +75%
    pt = (pitch - 50)              # -50Hz ~ +50Hz
    vol = (volume - 50) * 2        # -100% ~ +100%
    return rate, pt, vol


@app.route("/voices")
def voices():
    if not _authorized():
        return Response("unauthorized", 401)
    body = json.dumps({"voices": VOICES}, ensure_ascii=False)
    return Response(body, mimetype="application/json")


@app.route("/tts")
def tts():
    if not _authorized():
        return Response("unauthorized", 401)

    text = request.args.get("text", "").strip()
    if not text:
        return Response("missing text", 400)

    voice = request.args.get("voice", "zh-CN-XiaoxiaoNeural")
    speed = _clamp(request.args.get("speed"), 0, 100, 50)
    pitch = _clamp(request.args.get("pitch"), 0, 100, 50)
    volume = _clamp(request.args.get("volume"), 0, 100, 50)
    style = request.args.get("style", "").strip()
    rate, pt, vol = _map_units(speed, pitch, volume)

    log.info("synthesize voice=%s len=%d rate=%.0f%% pitch=%dHz vol=%.0f%% style=%s",
             voice, len(text), rate, pt, vol, style or "-")

    # edge-tts 7.x 移除了自定义 SSML 支持（服务端封禁），改用原生参数。
    # style 参数已无法注入（express-as 需要 SSML），记录后忽略。
    rate_s, vol_s, pitch_s = f"{rate:+.0f}%", f"{vol:+.0f}%", f"{pt:+d}Hz"
    log.info("synthesize voice=%s len=%d rate=%s pitch=%s volume=%s style=%s(ignored)",
             voice, len(text), rate_s, pitch_s, vol_s, style or "-")

    communicate = edge_tts.Communicate(
        text=text, voice=voice, rate=rate_s, volume=vol_s, pitch=pitch_s)
    buf = io.BytesIO()

    async def _collect():
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                buf.write(chunk["data"])

    try:
        asyncio.run(_collect())
    except Exception as e:  # 给出可读错误而非裸 500
        log.error("tts failed: %s", e)
        return Response(f"tts upstream error: {e}", 502)
    if buf.getbuffer().nbytes == 0:
        return Response("tts upstream returned no audio", 502)
    buf.seek(0)
    return Response(buf.read(), mimetype="audio/mpeg")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
