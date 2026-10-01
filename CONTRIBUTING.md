# Contributing to Quietpane

Thanks for looking. Quietpane is a small project with one maintainer, so anything you send gets read
by a person rather than a queue.

Three things are true of every change here, and the rest of this page is really just those three
spelled out:

- **Most contributions need no code at all.**
- **Side effects are described honestly**, even when that makes an item less appealing.
- **Nothing is proposed that hasn't been tried with Preview first.**

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Found a security problem?

**Please don't open an issue.** Email **info@komodoworks.com** with the subject "Security: Quietpane".
The [Security Policy](SECURITY.md) says what to include and what happens next. This matters more than
usual here: Quietpane can run with administrator rights, so a flaw in it is worth handling quietly until
there's a fix.

## Reporting a bug

Use **[New issue](https://github.com/kgntmr/quietpane/issues/new/choose)** and pick the bug form. It
asks for the version from the app's footer, your Windows version, and what happened - the same three
things the Security Policy asks for, because they're what make a report actionable.

One request: **don't paste a scan report into an issue, and remove anything personal first.** Reports
contain your username inside folder paths and the names of programs you use. They describe a real PC,
which is also why `.gitignore` keeps them out of the repository entirely.

## The easiest way to help: add a catalog entry

The lists Quietpane works from are plain data in [`src/catalog/`](src/catalog). Adding a setting, an
app, a folder, a brand or a startup note is **editing one file** - no code, no build step.

| File | What it holds |
|---|---|
| `privacy.psd1` | The privacy and telemetry settings in the Privacy tab |
| `apps.psd1` | Pre-installed apps offered for removal |
| `cleanup.psd1` | Places "Free up space" clears |
| `vendors.psd1` | Brand extras from NVIDIA, Intel, AMD, MSI, ASUS, Dell, HP, Lenovo, Acer |
| `startup.psd1` | Sign-in items never offered, and plain notes for common ones |
| `threats.psd1` | Defender threat names turned into two plain sentences |
| `extensions.psd1` | What a browser add-on permission actually means |
| `network.psd1` | Who is behind an address your PC is talking to |

Don't fancy Git? There's a **catalog entry** issue form. Describe the entry and it can be added for
you.

### What an entry looks like

Every field is explained at the top of `src/catalog/privacy.psd1` itself. Here is a real one, chosen
because it shows the two conventions that matter most:

```powershell
@{
    Id          = 'priv.location'
    Group       = 'Privacy'
    Title       = 'Turn off location for all apps'
    Short       = 'Side effect: weather, maps and Find my device may stop.'
    Description = 'Side effects: weather, maps, "Find my device" and automatic time zone may stop working. Leave unticked if you use them.'
    Recommended = $false
    Actions     = @(
        @{ Type = 'Reg'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'; Name = 'Value'; Value = 'Deny'; Kind = 'String' }
    )
}
```

The two conventions:

- **`Recommended = $false` is how a real cost is marked.** There's no separate risk field - this is
  it. If switching something off would stop a thing people use, it isn't recommended, however tempting
  the privacy win.
- **The side effect goes in `Short`**, not only in the long description, and it names what the person
  will *notice* rather than the mechanism. Nobody notices a registry value; they notice that the
  weather stopped working.

An app entry is one aligned line:

```powershell
@{ Name = 'Microsoft.BingWeather';  Title = 'Weather';  Recommended = $false; Description = 'Weather app. Keep it if you use it.' }
```

### House rules for the words

These aren't style preferences - the tests enforce them, and a pull request that breaks one goes red.

- **`Title` is nine words or fewer. `Short` is twelve or fewer.** Both `Short` and `Description` must
  be filled in.
- **No jargon in a `Title`.** The test rejects DiagTrack, group-policy, CEIP, registry and policy
  value outright. Say what it does, not what it's called.
- **Name the cost, then name what survives.** That second half is what lets someone decide:
  *"Programs behave the same; the reports just stay here."*  *"Switched off, never deleted."*
  *"Your lock-screen picture stays."*
- **`Group` must be one of the five headings already in the file, spelled the same way**, and `Id`
  takes the matching prefix - `tel.`, `priv.`, `ads.`, `svc.`, `app.`.
- **Apostrophes are doubled** inside single-quoted PowerShell strings: `'doesn''t'`.
- **A hyphen, not a dash**, in running text - like this.

### Two tests that will surprise you

Both are deliberate, and knowing about them saves an afternoon.

**The privacy item count is written into the test.** Adding a 33rd item to `privacy.psd1` fails this
until you change the number:

```powershell
$items.Count -eq 32 -and ...
```

It's in `tests/Run-QuietpaneTests.ps1`, in the section *Plain words, and something to do about them*.
The count is there on purpose: growing the list should be a decision somebody made, not something that
happens quietly.

**There's a word budget for the whole window.** Every tab is counted, and the total has a ceiling. If
your text is generous, that test is what tells you. Quietpane's promise is one plain line per thing,
and the budget is how that promise is kept.

## Anything involving code

- **Run it from source:** clone the repository and double-click `Start Quietpane.cmd`.
- **Try the window without showing it:** `.\Quietpane.ps1 -SelfTest`.
- **Run the checks:** `powershell -ExecutionPolicy Bypass -File tests\Run-QuietpaneTests.ps1`.
  Without administrator rights **326 checks run and 15 are skipped**. The
  [README](README.md#for-developers) has the elevated recipe for the rest.
- **Use Preview first.** If a change alters what happens to a PC, exercise it through Preview before
  proposing it. Preview is what stands between a person and a surprise.

### Line endings and plain ASCII

`.gitattributes` marks `*.ps1`, `*.psm1`, `*.psd1` and `*.cmd` as `-text`, so Git doesn't convert
anything - what's in the repository is exactly what lands on someone's PC. Those files must be saved
with **CRLF line endings and pure ASCII**, so that "Download ZIP" works on every PC, including ones
where PowerShell is fussier than yours.

You don't have to remember this. **CI checks it on every push**, and tells you which file and how many
lines are wrong. Markdown and YAML aren't covered, so they can be whatever your editor prefers.

## Why a thing is the way it is

Some of Quietpane's odder decisions have a story, and they're written down in
[`docs/LESSONS-LEARNED.md`](docs/LESSONS-LEARNED.md): what happened on a real machine, the evidence,
and then a bolded **Lesson:** saying what the tool does about it now.

If your change comes from something you learned the hard way, add it there in the same shape. That
file is the reason nobody has to re-learn why NVIDIA's telemetry plugin is blocked rather than deleted.

## Opening a pull request

The template lists what to check. In short: the tests pass, side effects are in `Short`, you tried it
with Preview, and if you grew a catalog you bumped the count the test expects.

Small and focused beats big and thorough. A one-line catalog addition is a perfectly good pull
request, and it's the kind this project needs most.

---

Questions that aren't a bug: **info@komodoworks.com**, or
[komodoworks.com/en/contact](https://komodoworks.com/en/contact).
