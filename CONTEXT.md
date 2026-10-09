# KikoFlu

KikoFlu combines audio playback and comic reading. Audio uses a persistent compact
surface and a full-screen player; comics use source-backed libraries and a
full-screen reader with shared playback access.

## Language

**Mini Player (播放条)**:
The persistent compact playback surface shown below the app's main content.
_Avoid_: Player bar

**App Tab Bar (应用标签栏)**:
The primary app navigation containing Audio, Comics, and Settings.
_Avoid_: Player navigation, bottom menu

**Audio Screen (音声页)**:
The app page that contains the Works Home Tab and the user's online marks,
history, playlists, downloads, and subtitle library tabs.
_Avoid_: Home page, My page

**Works Home Tab (主页标签)**:
The fixed first tab in the Audio Screen that displays the online works feed.
It is distinct from the Audio Screen, which also contains the user's library tabs.
_Avoid_: Audio Screen, app home page

**Global Works Search (全局作品搜索)**:
The server-backed work search opened from the Works Home Tab. Its results are
not restricted to another Audio Screen tab's collection.
_Avoid_: scoped search

**Scoped Search (范围搜索)**:
The shared search interface opened from a library tab. Its results are limited
to that tab's complete collection, such as one online-mark state, history,
playlists, or completed downloads.
_Avoid_: global works search

**Work Details Screen (作品详情页)**:
The online or offline screen describing a work and its available resource files.
It is distinct from the Player Audio Details Page for the current track.
_Avoid_: Player details page, audio details page

**Related Recommendations (相关推荐)**:
Works shown in the rightmost resource tab of an online Work Details Screen,
ranked using subject tags,
personal preferences, voice actors, circles, subtitle availability and public
ratings. Previously played works can remain in the list at a lower rank. When
the same work has Chinese editions, simplified Chinese is preferred over
traditional Chinese and other languages in recommendations.
_Avoid_: Popular works, random works

**Explicit Preference (明确喜好)**:
A preference signal from an account's ratings, replay or marked status, and
playlist membership. Device playback history is a separate, weaker signal.
_Avoid_: Listening history, public rating

**Exploration Recommendation (探索推荐)**:
A supplementary Related Recommendation selected from highly ranked remaining
candidates to add variety while keeping the same detail visit stable.
_Avoid_: Random recommendation, refresh result

**Work Resource Tabs (作品资源标签)**:
The Resources, Audio, Images and Related Recommendations views within a Work
Details Screen. Related Recommendations is the rightmost tab of online details
when enabled; Images is present only when the work has resource images. Audio
contains preferred audio files and their best matching work subtitles; Images
contains the work's resource images, separate from its cover.
_Avoid_: App Tab Bar, Works Home Tab

**Work Image Viewing (作品图片查看)**:
Viewing a work's resource images or cover with shared reader controls and settings.
It is separate from comic Reading Progress and does not add a comic history entry.
_Avoid_: Comic chapter, Reading Progress

**Best Work Subtitle (最佳匹配作品字幕)**:
The highest-scoring matching subtitle among a work's available resource files.
Equal scores prefer the audio's directory, then path order. The resource audio
view and player use this same selection; the player's subtitle library and manual
selection keep their own priority.

**Work Details Translation (作品详情翻译)**:
The translated view of a work's title and currently displayed resource names.
It remains active within that details page until the user switches back to the original.

**Automatic Work Details Translation (自动作品详情翻译)**:
The preference that enables Work Details Translation when a details page opens,
without requiring a manual translation action.

**Subtitle Preview Translation (字幕预览翻译)**:
The translated text shown while inspecting a work subtitle when Work Details
Translation is active. Otherwise, subtitle previews show the original text.

**Save Current Image (保存当前图片)**:
Exporting the reader's full loaded image bytes for the actual current page.
A two-image spread requires choosing one visible image before saving.

**Bottom Dock (底部 Dock)**:
The portrait Main Screen region formed by the Mini Player and App Tab Bar.
_Avoid_: Mini Player, App Tab Bar

**Player Cover Page (播放器封面页)**:
The full-screen player page containing the large artwork and primary playback
controls.
_Avoid_: Player home page, main page

**Player Queue Page (播放器队列页)**:
The full-screen player page containing the current playback queue. It is
distinct from the app-level playlist and playlist details screens.
_Avoid_: Player playlist page, playlist screen

**Audio Add Mode (音频添加模式)**:
The global preference that determines how selecting an audio item changes the
current playback queue: append it, play it next, or replace the queue.
_Avoid_: Playlist Add Mode, 播放列表添加模式

**Player Audio Details Page (播放器音频详情页)**:
The full-screen player page containing details for the current audio track. It
is distinct from the Work Details Screen for the containing work.
_Avoid_: Player details page, work details page

**Audio Subtitle Language (音频字幕语言)**:
The language of subtitles available for an individual audio file. A work's
Chinese-language label does not imply that every audio file has subtitles.
_Avoid_: Work language, audio language

**Audio Preferences (音频偏好)**:
The shared preferences for subtitle language, audio format order, sound effects
and ejaculation audio. They guide preferred work resources and default player
audio filtering.
_Avoid_: Audio Format Preference, player-only preferences

**Sound Effects (效果音)**:
The sound-effect component of an audio variant. A no-effects variant removes
that component while retaining the voice audio.

**Ejaculation Audio (射精音)**:
The ejaculation or climax audio component of an audio variant, classified
separately from Sound Effects.

**Player Lyrics Page (播放器字幕页)**:
The full-screen player page containing the current track's synchronized lyrics
or subtitles.
_Avoid_: Subtitle screen

**Playback Line (播放行)**:
The vertical anchor in the Player Lyrics Page where the current lyric or
selected search result is positioned while the player follows it.
_Avoid_: Center line, current line

**Repeat Mode (循环模式)**:
The playback rule that governs natural track completion and manual previous or
next navigation: sequential playback, single-track repeat, or queue repeat.
_Avoid_: Shuffle mode, Audio Add Mode

**Track Switch (曲目切换)**:
The playback request that prepares a source and commits the current track,
queue index, system media item, and restorable session. While loading, a new
request supersedes the previous target. Repeated next/previous requests advance
from the latest requested position. Only the winning request publishes a track;
canceling a load does not make a complete cache entry corrupt.
_Avoid_: Cover transition, title animation

**Playback Position Jump (播放进度跳转)**:
Moving to a selected time within the current track from the player's progress
control or lyrics. The current track and its queue position remain the same.
_Avoid_: Track Switch, 曲目切换

**Track Presentation Transition (曲目视觉过渡)**:
The existing cover and title animation after a committed track is published.
Its direction follows the accepted playback request. It is separate from source
preparation and does not block further track-switch requests.
_Avoid_: Track Switch, audio crossfade

**Cover Preview (封面预览)**:
The zoomable current-artwork view opened from the Player Cover Page. It is
distinct from the Player Cover Page and saves the unblurred source artwork.
_Avoid_: Player Cover Page, artwork editor

## 界面外观

**应用配色**：
主窗口中首页、设置页、列表页和底部迷你播放器共同使用的 Material 色彩方案。
_避免_：播放器视觉调色板、悬浮字幕配色

**动态取色**：
自动从当前播放封面派生应用配色的主题选择；当前播放封面不可用时使用系统动态颜色，系统动态颜色也不可用时使用已保存的固定颜色主题。
_避免_：封面模式、壁纸模式

**当前播放封面**：
播放会话中当前歌曲所关联的封面，不包括用户正在浏览但尚未播放的作品封面。
_避免_：当前页面封面、浏览封面

**固定颜色主题**：
动态取色关闭时使用并保留选择的命名应用配色，例如胖次蓝或哔哩粉。
_避免_：动态色、系统颜色

**播放器视觉调色板**：
完整播放器与应用配色共享同一个封面基础色。它保留适合模糊封面背景的局部背景和前景，强调色与应用配色一致；它不控制桌面悬浮字幕。
_避免_：应用配色、全局主题


**Comic Screen (漫画页)**:
The app page containing Home, Favorites, History, and Downloaded tabs. It shares
floating navigation and toolbar behavior with the Audio Screen.
_Avoid_: Works Home Tab, discovery page

**Comic Details Screen (漫画详情页)**:
The page describing one comic's synopsis, tags, chapters, and available actions.
It is distinct from the Comic Screen and Comic Reader.
_Avoid_: Comic Screen, Comic Reader

**Comic Reader (漫画阅读器)**:
The full-screen reading surface for a comic chapter, including paged, spread,
and continuous reading modes.
_Avoid_: Comic Details Screen, image gallery

**Reader Controls (阅读控制层)**:
The Comic Reader's toolbar, chapter and page controls, and shared Mini Player
shown over the reading surface.
_Avoid_: Bottom Dock, App Tab Bar

**Reader Settings (阅读器设置)**:
The shared Comic Reader preferences page opened from Reader Controls or Comic
settings. It contains reading mode, screen orientation, auto page-turn interval,
page-turn and zoom gestures, keep-awake, and preload preferences.
_Avoid_: Comic Source settings, Reader Controls

**Chapter Page Preview (章节页面预览)**:
A visual index of the individual comic images in one chapter used to choose an
image to read, opened from the Comic Details Screen or Reader Controls. It is
distinct from the Cover Preview and chapter catalog.
_Avoid_: Cover Preview, chapter catalog

**Chapter Thumbnails (章节缩略图预览)**:
Up to three comic images sampled evenly across a chapter, shown alongside its
entry in the Comic Details Screen. It is distinct from the Chapter Page Preview's
full image index.
_Avoid_: Chapter Page Preview, chapter catalog

**Reader Zoom (阅读器缩放)**:
The magnification of the current Comic Reader view: one page, one spread, or
the entire continuous strip. Images within that view share the same transform.
It is independent of the Reader Controls and the Cover Preview.
_Avoid_: Cover Preview, image gallery

**Comic Home Tab (漫画主页)**:
The first Comic Screen tab, showing recommendations and categories for the
selected enabled Comic Source, independent of the favorite collection. Its
anonymous access follows the Comic Source's browsing requirements.
_Avoid_: Comic Screen, source library

**Comic Collection Layout (漫画集合布局)**:
  The card presentation shared by the Home, Favorites, History, and Downloaded
  tabs: big grid, small grid with proportion-preserving covers in a denser
  masonry layout, or list. The small grid is the compact-cover view.
_Avoid_: Comic Reading Mode

**Comic Collection Page (漫画集合分页)**:
  Comic collections and full comic search present fixed-size groups of 20, 40,
  60, or 100 items (default 40), with a separate comic page-size preference.
  Users move between groups with Previous and Next. This is distinct from
  reader page turns and the masonry card layout.
_Avoid_: comic reader page, masonry layout

**Visited Comic Collection Page (已访问漫画集合页)**:
  A numbered group already displayed in the current collection or search
  results. Page-number jumps can target only these groups.
_Avoid_: comic reader page, fetched page

**Comic Source (漫画源)**:
One built-in provider of comic metadata, chapter images and optional account
features. Comic identity is sourceKey + comicId; chapter identity adds chapterId.
Credentials, capabilities, and network parsing belong to the source.
_Avoid_: audio server, custom script

**Local Favorite (本地收藏)**:
A comic saved in the device's comic database, independent of all accounts.
_Avoid_: downloaded comic

**Source Favorite (源站收藏)**:
A comic saved by a signed-in source account. The main favorite action prefers
this destination when supported, then also saves a Local Favorite. A failed
source write requires retry and does not silently become a Local Favorite.
_Avoid_: synchronized local favorite

**Reading Progress (阅读进度)**:
A source-qualified comic's chapter ID and zero-based actual image page index.
Online and downloaded reading share this position across display modes.
_Avoid_: audio playback position, spread index

**Anonymous Visitor (匿名游客)**:
A user without an active audio account. Startup does not submit demo credentials.
Audio requests use the saved server with no account credentials; each Comic
Source independently determines whether anonymous access is permitted.
_Avoid_: guest demo account, offline account
