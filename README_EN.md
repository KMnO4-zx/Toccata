<p align="center">
  <img src="shared/branding/toccata-app-icon.png" alt="Toccata" width="96">
</p>

<h1 align="center">Toccata</h1>

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

<p align="center">
  <strong>Capture ideas. See your effort.</strong><br>
  <em>Curious about your net active thinking time?</em>
</p>

<p align="center">
  <a href="https://github.com/KMnO4-zx/Toccata/releases">Download</a> ·
  <a href="develop.md">Developer Guide (Chinese)</a> ·
  <a href="CONTRIBUTING.md#english">Contribute</a> ·
  <a href="LICENSE">Apache-2.0</a>
</p>

## Why I Built This

I never used to bother with to-do apps. Keeping everything in my head worked just fine. Then work and study started piling up, and I finally needed somewhere to write things down.

My needs were simple: quickly see what I'd finished and what was still left to do, then pull up the week's tasks to write my weekly report. So I tried TickTick. I hated using it, and they still wanted my money!

**No way. So I built my own.**

I also really wanted to build something that tracks **“net active thinking time.”** Of all those hours at my computer every day, how much of that time is my mind actually active? Since I was already building my own app, I figured I'd add that too.

The name comes from [toccata](https://www.dictionary.com/browse/toccata), a piece of music for the keyboard. Its root is the Italian *toccare*, meaning “to touch.” I like that connection: fingers touch keys, and thoughts slowly become something you can see.

## To-Do Management

- **Capture on the fly**: open the menu bar window to add or edit tasks, with completed and pending items in view.
- **Organize at your pace**: break tasks into subtasks in the main window, write details in Markdown, set dates, and browse the task calendar.
- **Review your week**: gather completed and unfinished tasks, copy them with one click, and use them as the starting point for your weekly report.

![To-do management: main workspace on the left, menu bar window on the right](images/todo-management.png)

## Keyboard Activity: Net Active Thinking Time

There's something else I want to know: of all the time I spend at my computer, how much of it am I actually active? Taking a screenshot every few seconds and asking AI to analyze what I'm doing leaves me uneasy about privacy. So I turned to keyboard input.

My thinking is simple: **to the computer, I'm providing input; to myself, I'm producing output. When we're producing output, our minds are definitely active.** At that moment, the connection between me and the computer is right there, at the fingertips of both hands.

> And there's the connection: Toccata comes from the Italian *toccare*, “to touch.”

I want to use the keyboard to record the time I spend putting something out into the world. I call it **“net active thinking time.”** Honestly, I find that idea pretty sexy 🤔

- **Keyboard heatmap**: see which keys you use most, with live feedback as you press them.
- **Activity timeline**: see when you were typing throughout the day, and look back at your app usage and Fn hold time.
- **Local records**: key codes, timestamps, hold durations, and associated apps are recorded on your Mac. Capture takes no screenshots and records no audio.

![Keyboard activity: per-key heatmap and activity timelines for the last seven days](images/keyboard-activity.png)

> “Net active thinking time” is the idea behind this project. The actual duration is estimated from keyboard activity; it cannot directly measure thought or capture all the effort spent reading and thinking. Fn hold time serves as an estimate of spoken output and may also include shortcut use. See the [counting rules (Chinese)](develop.md#按键次数与活跃时间计算). The screenshots above use demo data.

## Get Started

For **Apple Silicon Macs · macOS 13+**. Download the DMG from [Releases](https://github.com/KMnO4-zx/Toccata/releases), then drag `Toccata.app` into Applications.

Once you have a version with in-app updates, use **About Toccata → Check for Updates** to download a newer release, then choose **Install and Restart**. Downloads can be cancelled or retried; tasks and keyboard records are saved before installation. The release page remains available when there is no compatible package. Older versions need one manual upgrade first.

Keyboard tracking requires permission under **System Settings → Privacy & Security → Input Monitoring**. Task management works independently.

Toccata stays in the menu bar and shows a Dock icon by default. Hide it under **Settings → General settings**. Click its menu bar icon to add and manage tasks, or right-click and choose **Open Workspace** for the full interface. Closing the workspace keeps Toccata running in the background; choose **Quit Toccata** to stop the app.

**Settings → General settings** brings together appearance, language, water reminders, launch at login, Dock visibility, and About. The appearance, language, and About shortcuts remain at the bottom left. Launch at login is off by default.

The menu bar panel also includes **Activity overview**, with Keyboard and Apps pages for today or yesterday. The Keyboard page shows a per-key heatmap and 15-minute activity segments with hover details. The scrollable Apps page lists every app by active time, showing both active time and key presses. Set **Default menu bar page** to Task management, Task calendar, or Activity overview under General settings. Task management is the default; each reopening uses your configured page.

Open General settings, or right-click the menu bar icon and choose **Water reminders…** to enable reminders based on key presses. The default interval is 8,192 presses, with a fresh count each day. You can change the interval and send a test notification. Enabling reminders requires notification permission; counts use the existing input monitoring records. Reminders continue with the workspace closed and stop when you quit the app.

Want to make it your own? Build instructions and development notes are in [develop.md (Chinese)](develop.md).

## Contributing

Contributions to code, documentation, translations, and testing are welcome. See the [contribution guide](CONTRIBUTING.md#english). The Windows port is looking for contributors: discuss ideas and pick a feature in [Windows support #1](https://github.com/KMnO4-zx/Toccata/issues/1), with client work in [apps/toccata-windows/](apps/toccata-windows/README.md#english).

## Thanks 🙏

- <img src="images/logos/kimi.png" width="20" height="20" alt="Kimi Logo"> &nbsp; Thanks to the **[Kimi Global Ambassador Program](https://www.kimi.com/zh-cn/lp/kimi-ambassador)**. Kimi K3.1 Pro is a great model for visual design!
- <img src="images/logos/openai-rounded.svg" width="20" height="20" alt="OpenAI Logo"> &nbsp; Thanks to the **[OpenAI Codex for Open Source program](https://developers.openai.com/community/codex-for-oss)** for giving me 12 months of ChatGPT Pro. GPT 6 Astra is a great coding model!
- <img src="images/logos/volcengine.png" width="20" height="20" alt="Volcengine Logo"> &nbsp; Thanks to the **[Volcengine Hero Program](https://developer.volcengine.com/)**. Doubao's multimodal capabilities are excellent!
- <img src="images/logos/datawhale.png" width="20" height="20" alt="Datawhale Logo"> &nbsp; Thanks to **[Datawhale](https://datawhale.cn/)**. A place to meet wonderful people on the same journey.
