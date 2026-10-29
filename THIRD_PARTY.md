# Third-party material in Awayke

## Sleepless (the project Awayke is based on)

Awayke is a fork of Sleepless, https://github.com/Aboudjem/Sleepless, Copyright (c) 2026 Adam Boudjemaa, MIT licence. The MIT licence requires the original copyright and licence notice to stay with the code; they are kept in `LICENSE` (both copyright lines) and credited in the README, CHANGELOG and app. Do not remove them. Adam Boudjemaa's commits are kept in this repository's history; if the history is ever squashed into a fresh repo, keep the LICENSE and credits.

## Insomnia (ideas and lists for the 1.5 and 1.6 features)

Several 1.5 features (adding time, the 5-minute notice, lid-closed actions, pausing apps, App Nap,
browser relaunch, update check, activity log) follow Insomnia, https://github.com/krishhgg/Insomnia,
Copyright (c) 2026 Krish Garg, MIT licence. Awayke's code for them is its own, but the lists of
apps that are never paused and the browser flags were adapted from Insomnia, so its notice is kept here:

> MIT License
>
> Copyright (c) 2026 Krish Garg
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction,
> including without limitation the rights to use, copy, modify, merge, publish, distribute,
> sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
> NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Other parts

| Part | Licence | Where |
| --- | --- | --- |
| Microsoft Edge WebView2 SDK 1.0.3912.50 (Windows app only), (c) Microsoft | BSD-style, see the NuGet package | NuGet reference in `windows/*.csproj`; the WebView2 Runtime itself is part of Windows and is not shipped |
| .NET 8 / Windows Forms (Windows app only, installed separately) | MIT | https://github.com/dotnet/runtime |

No fonts, sounds or other open-source code are bundled.

## Trademarks

Apple, Mac and macOS are trademarks of Apple Inc.; Windows is a trademark of Microsoft Corporation. Not affiliated with or endorsed by them.
