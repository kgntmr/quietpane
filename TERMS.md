# Terms of Use: Quietpane

**Last updated: 30 September 2026**

These terms explain, in plain language, how you may use Quietpane. The software itself is licensed under the [MIT License](LICENSE). Where these terms and the MIT License differ on copyright or licensing, the MIT License applies.

## 1. Who provides it
Quietpane is developed by **KomodoWorks**, an independent technology studio in Dublin, Ireland ([komodoworks.com](https://www.komodoworks.com)). Contact: **info@komodoworks.com**.
It is **free**. There's no purchase, no subscription, no account and no in-app offer.

## 2. What it does
Quietpane can look at your computer without changing it (the Safety scan, the Health tab - including asking the drive it runs from about its own temperature, wear and hours, which opens the drive read-only and alters nothing on it, and asking the graphics driver for its temperature, clocks and fan - "Where your space went", "What's talking to the internet", what each startup program costs you, what your browser add-ons are allowed to read, how your PC holds up over a session while you ask it to watch, Windows' own record of how steady it has been, and the record of which apps used your camera, microphone and location). When you choose to, it can also change Windows and application settings, switch off services, scheduled tasks and startup items, stop an app using the camera, microphone or location, tell a browser not to load an add-on you picked (a setting under your own account, which the browser reports as blocked by an administrator), add entries to the Windows hosts file, remove pre-installed apps, run a program's own uninstaller, move files and folders you pick to the Recycle Bin, write a session up as a page on your Desktop when you ask for it, unpack and start a newer Quietpane you have downloaded yourself, when you choose to install it (it never downloads one), add or remove its own Start menu and desktop shortcuts, start itself when you sign in (a task in Task Scheduler) and, if you choose, check once at that moment for anything that switched itself back on, keep its own copy in Program Files for those two to open, and deal with threats: ask Microsoft Defender to remove them, quarantine them, or delete them.

**It only makes changes you have chosen and confirmed.** Before applying settings you can use "Preview" to see exactly what would change.

Most changes are recorded in a restore point that you can undo, and clean-up only ever moves files to your Recycle Bin. Three things cannot be undone by Quietpane, and the app says so before you confirm them:
- **removing an app** (you can reinstall it from the Microsoft Store);
- **uninstalling a brand extra** (you can reinstall it from its maker);
- **deleting a threat for good** (you're asked twice).

## 3. Using it responsibly
- Use it only on computers you own or are authorised to administer. On a work or school computer, ask the administrator first, because changing settings may conflict with your organisation's policies.
- Read each item's description, including its side effects, before applying it.
- Keep backups of important files, as you would before any system change.
- The app opens with your own rights and asks Windows for administrator rights only when a change you press needs them, such as a system setting, a service or the quarantine. Saying yes lets that window make the changes you then confirm; it does nothing by itself.

## 4. No warranty
Quietpane is provided free of charge, **"as is"**, without warranty of any kind, to the extent permitted by applicable law. Every PC is different, and Windows and third-party updates can change how settings behave. We can't guarantee the app will suit your particular system.

The Safety scan relies on Microsoft Defender and on Quietpane's own checks. **It cannot guarantee that a PC is free of malware**, and a finding from Quietpane's own checks is a signal, not proof.

**Health readings** come from Windows, from your drivers and - for the drive's temperature, wear and hours - from the drive itself, and may be approximate. The processor's temperature comes from Windows' thermal sensor, which on some PCs is a sensor near the chip rather than the chip; reading the chip directly would need a kernel driver, and Quietpane will not install one. Clock speeds, fan speeds and other sensor readings depend on what your hardware, its driver and its maker choose to share with Windows, and many PCs share only some of them - fan speed, in particular, is usually kept to the maker's own app. Where a figure cannot be had, the app leaves it out or says **not shared** rather than showing a number: **it never fills a missing reading in, guesses one, or shows a zero in its place.** The single sentence at the top of the Health tab is a **summary of those same readings, not advice**: it says what is happening, never what you ought to do about it, and it is not a diagnosis of a hardware fault. If you think a drive or battery is failing, use the manufacturer's own tools and keep backups.

**Browser add-ons:** Quietpane reports what an add-on asks the browser for, as written in the add-on's own manifest. It cannot tell a useful add-on from a harmful one - an ad blocker and a password stealer ask for the same things - and it does not judge one. Switching an add-on off uses the browser's own policy setting, which the browser reports as blocked by an administrator.

"Where your space went" measures what Windows lets it see: what it cannot read, and Windows' own folder, are reported together as "Windows and system files" rather than guessed at. **"Worth clearing first" is a suggestion, not a judgement**: it goes by the date written on a file, because Windows' record of when a file was last opened is updated by anything that reads it. Only you know whether you still want something, so nothing there is ticked, recommended or moved unless you press the button, and everything goes to your Recycle Bin. "What's talking to the internet" is a snapshot of the connections Windows lists at that moment; connections made over QUIC are not listed by Windows, and a note about an address being usage data or ads is judged from its name alone, not from what is actually sent.

## 5. Liability
To the fullest extent permitted by law, KomodoWorks is not liable for indirect or consequential loss, loss of data, or loss caused by third-party software or updates, arising from the use of this free software.
**Nothing in these terms limits or excludes liability that cannot be limited or excluded by law**, including liability for fraud, or for death or personal injury caused by negligence. Nothing here affects your statutory rights as a consumer.

## 6. Third-party software and trademarks
Windows, Microsoft Defender, Microsoft Edge, Microsoft 365, Microsoft Office, Xbox and Visual Studio Code are trademarks of Microsoft. NVIDIA and GeForce are trademarks of NVIDIA. Intel is a trademark of Intel. AMD and Radeon are trademarks of Advanced Micro Devices. Google Chrome is a trademark of Google. MSI, ASUS, Dell, HP, Lenovo, Acer and other names belong to their owners.
**Quietpane is independent and is not affiliated with, endorsed by or sponsored by any of these companies.** It only uses settings, policies and uninstall mechanisms those products already provide. Your use of their software remains subject to their own terms.

## 7. Security
Please report security issues privately, as described in [SECURITY.md](SECURITY.md).

## 8. Changes
We may update these terms. The date above changes, and the full history is visible in the GitHub repository. The terms that were current when you downloaded a version apply to that version.

## 9. Law and courts
These terms are governed by the laws of Ireland, and the courts of Ireland have jurisdiction. If you're a consumer living in another EU country, you keep the protection of the mandatory laws of your country, and you may also bring proceedings in the courts where you live.

## 10. Contact
**info@komodoworks.com** · [komodoworks.com](https://www.komodoworks.com)
