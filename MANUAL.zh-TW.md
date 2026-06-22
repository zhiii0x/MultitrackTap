# Multitrack Tap — 使用手冊

[English](MANUAL.md) · 繁體中文

錄音、設定、輸出與疑難排解的使用說明。專案總覽請見 [README](README.zh-TW.md)。

---

## 系統需求

- macOS **14.4(Sonoma)** 以上——Core Audio process taps 必需
- Apple Silicon 或 Intel 皆可

## 安裝

已簽章的 DMG 與 Homebrew cask 在規劃中。目前請從原始碼自行建置:

```bash
git clone https://github.com/zhiii0x/MultitrackTap.git
cd MultitrackTap

# 跑核心單元測試(可選)
swift test

# 建置並組裝 .app,然後啟動
cd app
./make-app.sh
open "Multitrack Tap.app"
```

> App 必須從組裝好的 `.app` bundle 執行(不能用 bare `swift run`),macOS 才能把
> 音訊錄製權限歸給它。

## 第一次啟動與權限

Multitrack Tap 需要兩個權限,會在你第一次錄到對應來源時請求:

| 權限 | 用於 | 在哪裡授予 |
|---|---|---|
| **麥克風** | 錄製麥克風 | 系統設定 → 隱私權與安全性 → **麥克風** |
| **系統音訊錄製** | 錄製系統音訊與任何 app | 系統設定 → 隱私權與安全性 → **螢幕與系統音訊錄製** |

權限尚未授予的來源,會在電平表的位置顯示一個小小的琥珀色 **Allow** 按鈕——點它即可授予
(若先前被拒,則會開啟對應的系統設定頁)。只錄麥克風不需要系統音訊權限。

> **重要——授予「系統音訊錄製」後要結束並重新打開 App。** macOS 只會把這個權限套用到
> *重新啟動過* 的 App。如果你在 Multitrack Tap 執行中途才授予,app 清單會一直是空的、taps 也
> 會沒聲音,直到你 **⌘Q 後重新打開**——這種情況下 app 會顯示一鍵 **Quit & Reopen** 按鈕。
> 每台 Mac 只需在第一次授予後做這一次。

> **開發者注意:** `make-app.sh` 預設是 **ad-hoc 簽章**,而 macOS 把「系統音訊錄製」授權
> 綁定在程式碼簽章上——所以每次重新 build 都會重置。本機開發時請改用穩定簽章身分以保留授權:
> `SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-app.sh`(或一張自簽的
> 程式碼簽章憑證)。

## 錄音

主視窗:

1. **輸出資料夾** ——錄音存放位置(預設 `~/Recordings`)。用 **Choose…** 變更。每段錄音
   都會放進自己的時間戳子資料夾,所以不會互相覆蓋。
2. **來源(Sources)** ——**麥克風**、**系統音訊**,以及每個正在發聲的 app 各一列。勾選你
   要的來源;每個都有即時電平表,讓你錄之前先確認它有訊號。
3. **Record** ——按 **Record**(或 **⌘R**)開始。錄音中會顯示計時與呼吸式紅點,來源清單
   會被鎖定。按 **Stop**(或 **⌘R**)結束。

也可以用**選單列圖示**直接開始/停止,不必開視窗。

**逐來源容錯:** 若某個被選的來源在開始時無法擷取(例如某 app 剛好在此時退出),它會被略過、
其餘照常錄音——並用琥珀色提示標出被略過的來源。只有「所有來源都無法擷取」時才會中止。

## 設定(⌘,)

- **取樣率** ——44.1 / 48 / 88.2 / 96 kHz。每條分軌都會擷取(或重新取樣)到這個取樣率,
  Reaper 專案也用它,所以所有軌道都對得齊。
- **位元格式** ——16-bit、24-bit,或 **32-bit float**(預設;不爆音)。
- **產生 Reaper 專案** ——在分軌旁一併寫出可立即打開的 `.rpp`。
- **錄完後在 Finder 顯示** ——停止時自動打開輸出資料夾。

## 輸出

每個錄音資料夾包含:

- **每個來源一條 WAV 分軌**,依來源命名(例如 `Microphone.wav`、`Firefox.wav`、
  `System audio.wav`),全部**歸零對齊**,從同一瞬間開始。
- **`project.rpp`**(若啟用)——用 [REAPER](https://www.reaper.fm/) 打開,每條軌道都已
  命名並對齊到時間 0。你也可以直接把 WAV 分軌拖進任何 DAW 或剪輯軟體。

## 錄音歷史(⌘0)

**Recordings** 視窗列出過往的錄音,含日期、長度、分軌數、格式,以及在 Finder 顯示的按鈕。
移除一筆紀錄不會刪除硬碟上的檔案。

## 當機修復

錄音中 WAV header 會定期回寫;下次啟動時,任何被中斷(當機/強制結束)的錄音,其分軌 header
會被自動修復——所以被中斷的錄音仍會留下可正常播放的 WAV 檔。

## 疑難排解

- **某來源一直顯示「Allow」/ 錄不到系統音訊** ——系統音訊錄製權限沒授予。點 **Allow**,或到
  系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製 授予。(開發者:見上方 ad-hoc 簽章注意事項——
  重新 build 會重置授權。)
- **已授予「系統音訊錄製」,但清單仍空白 / 錄不到任何東西** ——macOS 只把授權套用到重新啟動過的
  App。請 **⌘Q 結束後重新打開** Multitrack Tap(或點空清單裡的 **Quit & Reopen** 按鈕)。
  每台 Mac 在第一次授予後需要做這一次。若仍無效,重置後再授予一次:
  `tccutil reset All com.github.zhiii0x.multitracktap`,然後重開並重新授予。
- **某 app 沒出現在來源清單** ——只有**正在發聲**的 app 會列出。在該 app 開始播放,再按
  **重新整理(↻)**。會把音訊渲染在 helper process 的 app(Chrome/Arc/Electron、瀏覽器版
  會議工具)會透過比對該 app 所有音訊 process 來擷取。
- **錄出來速度太快/太慢** ——已修正:process-tap 分軌現在使用輸出裝置的真實取樣率,不會再被
  標錯。如果你建置的是舊版本,請從 `main` 重新 build。
- **分軌對不齊** ——所有來源共用同一個 host-time 參考時脈,每條分軌前面會補靜音以從專案
  時間 0 開始;這由單元測試驗證。

## 關於

**About Multitrack Tap**(app 選單)顯示版本,並連到專案與授權。

## 授權與致謝

[MIT](LICENSE) © 2026 Zhiii。本專案的 Core Audio process-tap 與音源列舉程式碼改寫自
[AudioCap](https://github.com/insidegui/AudioCap)(作者 Guilherme Rambo,授權
[BSD-2-Clause](THIRD-PARTY-LICENSES.md))。
