# Iroru

Iroru combines audio playback, comic reading, and video playback. Audio uses a
persistent compact surface and a full-screen player; comics use source-backed
libraries and a full-screen reader with shared playback access. Video uses a
separate inline player with full-screen playback and local downloads.

## Language

**Mini Player (播放条)**:
The persistent compact playback surface shown below the app's main content.
_Avoid_: Player bar

**App Tab Bar (应用标签栏)**:
The primary app navigation containing Audio, Comics, Videos, and Settings.
Audio, Comics, and Videos each retain their browsing history when another entry
is selected.
_Avoid_: Player navigation, bottom menu

**Video Screen (视频页)**:
The app page for browsing videos from a Video Source.
_Avoid_: Video player, source website

**Video Collection Layout (视频集合布局)**:
The presentation of video cards and Video Playlist cards as a big grid, small
grid, or list.
_Avoid_: Video playback mode

**Four-line Card Title Height (作品卡片四行标题高度)**:
作品卡片采用当前字体、字号、行高和系统文字缩放时，4 行标题占用的高度。
该高度与单个标题实际显示的行数无关。

**Video Catalog Number (作品番号)**:
The identifier assigned to a video work, independent of a Video Source's page
identifier and version labels such as subtitle or uncensored variants.
_Avoid_: Video ID, page identifier

**Video Content Navigation (视频内容导航)**:
The curated entries for directly browsing a Video Source's video collections.
Search conditions belong to Video Search Filters.
_Avoid_: Video Search Filters, Source website services, Video Collection Layout

**Recommended for You (推荐给你)**:
The recommendation collection presented on a Video Source's home page.
_Avoid_: Related Recommendations, Video Details Screen recommendations

**New Releases (新作上市)**:
The Video Source's collection of newly released videos, distinct from recently
updated videos.
_Avoid_: Latest updates

**Video Search Filters (视频搜索筛选)**:
Conditions such as category, actor, or studio that narrow a video search.
_Avoid_: Video Content Navigation, Video Collection Layout

**Video Collection Page (视频集合分页)**:
A numbered portion of a video feed, search result, or download list.
_Avoid_: Video Resume Position

**Video Source (视频源)**:
A provider of video catalogs and playback, such as MissAV (missav.ai) and
Jable (jable.tv).
_Avoid_: Audio Source, Comic Source

**Video Source Account (视频源账号)**:
A user's account with a Video Source and the source-owned collections belonging
to that account.
_Avoid_: Audio account, comic account

**Video Source Verification (视频源验证)**:
The website check required before a Video Source permits access from the current
network. It is separate from signing in to a Video Source Account.
_Avoid_: Video account login

**Video Details Screen (视频详情页)**:
The app page containing one video's inline Video Player, information, and related
recommendations.
Switching to another App Tab Bar entry pauses the Video Player. The Video Player
remains paused on return until playback is resumed manually.
_Avoid_: Video Screen, source website

**Video Related Recommendations (视频相关推荐)**:
Videos related to the current video and shown in its Video Details Screen. For
MissAV, they come from the Video Source's recommendations for that video.
_Avoid_: Recommended for You

**Video Basic Information (视频基础信息)**:
A video's source-provided information outside its genre, maker, label, series,
director, and actor classifications, such as its catalog number, release date,
and duration.

**Video Directory Link (视频目录链接)**:
A Video Source link to videos sharing a genre, maker, label, series, director,
or actor. A metadata name can exist without a Video Directory Link.

**Video Player (视频播放器)**:
The viewing and playback-control surface for a video, including inline and
full-screen modes, playback gestures, and playback options. Video metadata and
related recommendations belong to the Video Details Screen.
_Avoid_: Video Screen, Video Details Screen

**Video Playback Settings (视频播放设置)**:
Preferences controlling a Video Player's playback and interactions. They are
separate from the video card fields shown while browsing.
_Avoid_: Video card settings

**Video First Frame Wait (视频首帧等待)**:
从触发视频卡片或播放器播放按钮，到视频播放器显示首个可见视频画面的时间。
视频自带的片头黑场也会延长这段等待。

**Video Controls (视频控制层)**:
The Video Player's title bar, progress control, and playback actions shown over
the viewing surface.
_Avoid_: Video picture, Video Playback Settings

**Video Playback Feedback (视频播放操作提示)**:
A temporary indication inside the Video Player describing an operation, such as
seeking or adjusting volume or brightness. It is separate from Video Controls.

**Video Side Bars (视频左右黑边)**:
The areas to the left and right of the video picture inside the Video Player
when the picture is narrower than the viewing surface.
_Avoid_: System safe area, page margin

**Video Source Favorite (视频源收藏)**:
A video saved in a Video Source Account's collection, belonging to that account.
On Jable, Favorites and Watch Later are separate collections.
_Avoid_: Local Favorite, comic Source Favorite

**Video Playlist (视频播放列表)**:
A collection of videos stored by a Video Source for a Video Source Account.
_Avoid_: Playback queue

**Video Playlist Cover (视频播放列表封面)**:
The cover of the first video in a Video Playlist, in Video Source order.

**Video Watch History (视频观看历史)**:
A Video Source Account's list of watched videos.
_Avoid_: Video Resume Position, audio playback history

**Video Resume Position (视频续播进度)**:
The saved playback time used to resume a particular video.
_Avoid_: Video Watch History, Reading Progress

**Video Download (视频下载)**:
A saved copy of a video for playback without access to its Video Source.
_Avoid_: Video Source Favorite, playback buffer

**Simultaneous Audio and Video Playback (音声与视频同时播放)**:
Playing an audio track and a video at the same time, each with independently
adjustable volume.

**Audio Screen (音声页)**:
The app page that contains the Works Home Page and the user's online marks,
history, playlists, downloads, and subtitle library pages. A fixed header shows
the menu button, current page name, and an entry to the scoped search screen.
The sidebar separates source-account entries, including sign-in, from public
browsing and local collections. The current page's options appear beneath its
entry, with shared browsing options in a separate group; swiping right across
the main content opens it.
_Avoid_: Home page, My page

**Audio Collection Layout (音声集合布局)**:
The shared presentation of audio work and playlist cards on the Audio Screen and
in audio search results: big grid, small grid, or list. It excludes the subtitle
library's hierarchical file list.
_Avoid_: Audio player layout

**Audio History Visit (音声历史浏览)**:
A visit to audio history that ends when switching to another Audio Screen page or
another App Tab Bar entry. Pagination, a Work Details Screen, Scoped Search
opened from history, and backgrounding the app do not end the visit.

**Audio Source (音声源)**:
A provider of audio works for independent browsing, search and playback, such as
ASMR.ONE or Japanese ASMR (jp-asmr, japaneseasmr.com).
_Avoid_: Playback fallback, mirror server

**Automatic Work Marking (作品自动标记)**:
根据收听和安排播放的行为，自动更新音声作品在音声源账号中的在线标记。
作品自动标记仅适用于支持在线标记的音声源。

**Works Home Page (作品主页)**:
The online works feed opened by selecting an Audio Source in the drawer,
including the currently selected source. The drawer also has a fixed Home entry.
The Audio Screen also contains the user's library pages.
_Avoid_: Audio Screen, app home page

**Popular Works Page (热门页)**:
The selected Audio Source's works feed ranked by the source's native popularity
measure for a chosen period. It is separate from Related Recommendations.
_Avoid_: Recommended works

**Works Sort (作品排序)**:
The field and direction that determine the order of an Audio Source's works feed.
Each Audio Source has a separate Works Sort. Age Rating Filter independently
determines which works appear in the feed.

**Age Rating Filter (年龄分级筛选)**:
A restriction of a works feed or work search results to the selected Audio Source's age classification.
“全部” includes every age classification supported by that source;
individual classifications use 全年龄, R15, and R18.
_Avoid_: Age rating sort

**Automatic Work Translation (自动翻译)**:
Automatic translation of an audio work's detail title, visible resource names,
and subtitle previews into the selected target language.
_Avoid_: Lyric translation, comic translation

**Subtitle Filter (字幕筛选)**:
“有字幕”仅包含音声源标记为有在线字幕的作品。本地字幕不属于字幕筛选范围。
筛选后的作品按当前排序分页；切换筛选从第 1 页开始。

**Global Works Search (全局作品搜索)**:
The online work search opened from the home, popular, or recommended feed for the
selected Audio Source. These feeds search that source's full catalog. Library
pages search their own complete collections.
_Avoid_: scoped search

**Scoped Search (范围搜索)**:
The shared search interface opened from a library page. Its results are limited
to that page's complete collection, such as an audio online-mark state, history,
playlists, or completed downloads; comic favorites; or video downloads. The
collection remains the search scope until the search closes.
_Avoid_: global works search

**Audio Search Catalog (音声搜索目录)**:
An Audio Source's lists of tags, voice actors, and circles used to choose work
search conditions. Catalog entries identify a tag, voice actor, or circle; they
are distinct from the matching works. An Audio Source may not provide a catalog.

**Audio Tag (音声标签)**:
A classification attached to an audio work. Its source-provided name and
translated names refer to the same Audio Tag. Tag search can match either name.

**User-added Audio Tag (用户添加的标签)**:
由音声源用户补充的作品标签，与作品默认标签区分。
标签来源不表示票数高低。
_避免_：低愿力标签、低票数标签

**Work Details Screen (作品详情页)**:
The online or offline screen describing a work and its available resource files.
It is distinct from the Player Audio Details Page for the current track.
Opening a Work Details Screen from the full-screen audio player closes the
player and shows the Mini Player. If the current screen already shows that work,
it retains its state. Otherwise, the app switches to Audio and opens the screen.
Returning from a Work Details Screen to a search started in the player preserves
the search's filters, page, and scroll position.
_Avoid_: Player details page, audio details page

**Work Audio Chapter (作品音频章节)**:
An individually playable, named section of an audio work, bounded within the
complete work's timeline. It is distinct from a separately supplied audio file
and from a comic chapter.

**Completed Audio (已听完音频)**:
播放到末尾并结束的单段作品音频。拖动到末尾后结束也算已听完。
_避免_：作品“听过”标记

**Audio Completion Record (音频完成记录)**:
本机保存的某个音声源账号听完某段音频的记录。清除播放历史不会清除此记录。
_避免_：播放历史

**Work Queue Completion (作品队列完成情况)**:
当前播放队列中一部作品的各段音频，在该队列内的听完情况。
其他队列的完成情况不计入。
_避免_：音频完成记录

**Related Recommendations (相关推荐)**:
Works shown in the rightmost resource tab of an online Work Details Screen,
ranked using subject tags,
personal preferences, voice actors, circles, and public
ratings. Previously played works can remain in the list at a lower rank. When
the same work has Chinese editions, simplified Chinese is preferred over
traditional Chinese and other languages in recommendations.
Japanese ASMR does not currently provide Related Recommendations.
_Avoid_: Popular works, random works

**Explicit Preference (明确喜好)**:
A preference signal from an account's ratings, replay or marked status, and
playlist membership. Marks set by Automatic Work Marking are included. Device
playback history is a separate, weaker signal.
_Avoid_: Listening history, public rating

**Exploration Recommendation (探索推荐)**:
A supplementary Related Recommendation selected from highly ranked remaining
candidates to add variety while keeping the same detail visit stable.
_Avoid_: Random recommendation, refresh result

**Work Resource Tabs (作品资源标签)**:
The Resources, Audio, Images, Videos, and Related Recommendations views within a
Work Details Screen. Related Recommendations is the rightmost tab of online
details when available and enabled; Images and Videos are present only when the
work has resource images or videos, respectively. Videos follows Images and precedes
Related Recommendations. Audio
contains preferred audio files and their best matching work subtitles; Images
contains the work's resource images, separate from its cover. Videos contains the
work's resource videos.
For Japanese ASMR works with a chapter index, Audio lists the Work Audio Chapters
in source order in place of the complete-work audio entry.
Each tab retains its resource-section scroll position during the current detail
visit; an unvisited tab starts at the resource section's top.
Swiping before the tab bar pins preserves its position on screen.
Pages slide out and in at their own browsing positions throughout the transition.
_Avoid_: App Tab Bar, Works Home Tab

**Work Resource Video (作品资源视频)**:
A video file supplied among an audio work's resources, separate from videos
cataloged by a Video Source.

**Same-folder Work Videos (同文件夹作品视频)**:
Work Resource Videos directly contained in the same resource folder. Videos in
child folders belong to their own folder.

**Work Image Viewing (作品图片查看)**:
Viewing a work's resource images or cover with shared reader controls and settings.
It is separate from comic Reading Progress and does not add a comic history entry.
_Avoid_: Comic chapter, Reading Progress

**Subtitle Archive Import (字幕压缩包导入)**:
Adding subtitle files from an archive to the subtitle library, including making
saved subtitles available there. If the library update fails, saved files remain
and the import result reports the failure.
_Avoid_: Archive extraction

**Partial Subtitle Archive Import (字幕压缩包部分导入)**:
An archive import that saves at least one subtitle and reports at least one
import failure. Saved subtitles remain in the subtitle library. The result
reports both the imported and failed counts.
_Avoid_: Complete import failure

**Best Work Subtitle (最佳匹配作品字幕)**:
The matching subtitle that first prefers the effective global translation target
language, identified by explicit file or directory language labels, then match
score, the audio's directory, and path order. Without a target-language match,
the existing score and path ordering applies. The resource audio view and player
use this same selection; the player's subtitle library and manual selection keep
their own priority.

**Work Details Translation (作品详情翻译)**:
The translated view of a work's title and currently displayed resource names.
It remains active within that details page until the user switches back to the original.
Automatic and manual translation resolve the source language separately for the
title and each resource name. Hiragana, Katakana, and half-width Katakana select
Japanese; text without Kana uses the work's recognized language. Matching source
and effective target languages keep the original text;
Simplified and Traditional Chinese use local OpenCC conversion. Other recognized
languages are sent to translation sources with each text's resolved source.
When text has no Kana and the work language is missing or unknown, clearly
Chinese text targeting Chinese uses local conversion; other text uses automatic
source detection.
Original text and local conversion take precedence over translation-source caches.
Local conversions of titles, resource names, and full subtitle text are cached
persistently by source and target language, separately from remote translations.
Translation-source failures trigger fallback sources before returning the original;
only successful responses enter the remote cache. Resource names are grouped by
their resolved source language before batching, and caches use that same source.
Resource-name batches keep their original names when the response has missing,
extra, or empty lines.

**Automatic Work Details Translation (自动作品详情翻译)**:
The preference that enables Work Details Translation when a details page opens,
without requiring a manual translation action.
Each text whose resolved source matches the effective translation target stays
original while other texts in the same work can be translated. Manual translation
uses the same policy.

**Text Preview (文本预览)**:
The reading and editing view for a work's subtitle or other text file, also used
for subtitles opened from the subtitle library or player. It is distinct from
the synchronized display in the Player Lyrics Page.

**Subtitle Preview Translation (字幕预览翻译)**:
The translated text shown while inspecting a work subtitle when Work Details
Translation is active. Otherwise, work subtitle previews show the original text.
Translation uses the current original text, including edits. Editing the original
invalidates its previous translation.

**Save Current Image (保存当前图片)**:
Exporting the reader's full loaded image bytes for the actual current page.
A two-image spread requires choosing one visible image before saving.

**Bottom Dock (底部 Dock)**:
The persistent Mini Player and app navigation shared by browsing pages.
App navigation stays below the content in portrait and on the left in landscape.
Full-screen audio playback, comic reading, and full-screen video hide this surface
when fully open. During landscape audio player transitions, the player covers or
uncovers the stationary left navigation. Navigation becomes interactive after
the player finishes closing. The Bottom Dock stays hidden while the full-screen
audio player is fully open, including when Cover Preview or a lyric text preview
is open.
_Avoid_: Mini Player, App Tab Bar

**Player Cover Page (播放器封面页)**:
The full-screen player page containing the large artwork and primary playback
controls.
_Avoid_: Player home page, main page

**Player Queue Page (播放器队列页)**:
The full-screen player page for browsing the current playback queue and
Historical Playback Queues. It is distinct from the app-level playlist and
playlist details screens.
_Avoid_: Player playlist page, playlist screen

**Historical Playback Queue (历史播放队列)**:
A previously used audio playback queue retained for later browsing. It is
distinct from per-work playback history and account playlists.
_Avoid_: Playback history, account playlist

**Queue Ordinal (队列序号)**:
The position assigned to a playback queue during one visit to the Player Queue
Page. It is distinct from a track's position within a queue.
_Avoid_: Track position, track index

**Audio Add Mode (音频添加模式)**:
The global preference that determines how selecting an audio item changes the
current playback queue: append it, play it next, or replace the queue.
_Avoid_: Playlist Add Mode, 播放列表添加模式

**Player Audio Details Page (播放器音频详情页)**:
The full-screen player page containing details for the current audio track. It
is distinct from the Work Details Screen for the containing work.
Opening a metadata search closes the player, shows the Mini Player, and switches
to Audio.
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

**Current Playback Subtitle (当前播放字幕)**:
The subtitle corresponding to the audio's actual playback position. It can
differ from the subtitle at the Playback Line while browsing or searching.

**Subtitle Spring Motion (字幕弹簧动画)**:
The elastic movement of subtitle lines as the Player Cover Page and Player
Lyrics Page follow playback or move to a selected subtitle. Shared subtitle
actions use the same motion on both pages. It is distinct from word-by-word
highlighting.
_Avoid_: Karaoke animation, word highlighting

**Subtitle Emphasis (字幕强调)**:
The brightness and apparent size that distinguish the active subtitle line from
inactive lines on the Player Cover Page and Player Lyrics Page.

**Subtitle Spring Preset (字幕弹簧预设)**:
A named motion style for Subtitle Spring Motion, describing its response and
bounce. It is independent of subtitle font and line-height preferences.

**Translation Source (翻译源)**:
The translation provider selected in Settings, with the app's existing fallback
providers used when the selected provider fails.

**Playback Line (播放行)**:
The vertical anchor in the Player Lyrics Page where the current lyric or
selected search result is positioned while the player follows it.
_Avoid_: Center line, current line

**Playback Line Time (播放行时间)**:
The start time, on the current track's timeline, of the subtitle indicated by
the Playback Line. It can differ from the actual playback position while
browsing or searching subtitles.
_Avoid_: Playback position, playback clock

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

**Audio Slice (音频切片)**:
A saved start and end range within one playable audio track, shared by online,
cached, and downloaded playback of that same track. Each Work Audio Chapter has
independent slices on its own timeline starting at zero.
_Avoid_: Point marker, exported audio clip, Work Audio Chapter

**Current Audio Slice (当前切片)**:
The saved Audio Slice containing the current playback position, including while
playback is paused. It is independent of the Selected Audio Slice and Slice Preview.

**Selected Audio Slice (选中切片)**:
The Audio Slice explicitly chosen for inspection or editing during the current
slice manager visit. Selection ends when the manager closes or the track changes.

**Slice Preview (切片试听)**:
Playback of one selected Audio Slice once, followed by a pause at its end.
_Avoid_: Single-track repeat, Only Slices Mode

**Only Slices Mode (仅播放切片)**:
The playback rule that skips gaps during playback and plays a track's Audio
Slices in time order; paused playback keeps the selected position.
At the final slice, Repeat Mode determines whether playback returns to the first
slice or advances to the next track.
_Avoid_: Slice Preview, audio-file trimming

**Automatic Audio Cache (音频自动缓存)**:
Saving online audio in the background for later playback. A cache entry becomes
playable only when the entire file is saved. Cache progress, failure, or
cancellation does not change the current playback source.
_Avoid_: Audio Download, playback buffer

**Next Track Preload (下一首预加载)**:
Preparing the next queued track ahead of a Track Switch, using the configured
remaining-time threshold. It may prepare a playback source or save audio through
Automatic Audio Cache, without changing the currently published track.
_Avoid_: Track Switch, playback buffer

**Track Presentation Transition (曲目视觉过渡)**:
The cover and title animation after a committed track is published. The title's
direction follows the accepted playback request. The transition is separate from
source preparation and does not block further track-switch requests.
_Avoid_: Track Switch, audio crossfade

**Player Cover Scale (播放器封面缩放)**:
The Player Cover Page artwork size that reflects playback and loading states. It
is separate from user-controlled zoom in Cover Preview.
_Avoid_: Cover Preview zoom, Track Presentation Transition

**Cover Preview (封面预览)**:
The zoomable artwork view opened from the Player Cover Page, Work Details Screen,
or Comic Details Screen. Artwork is centered in the full window and can be zoomed
and panned across it. It is distinct from the Player Cover Page and saves the
unblurred source artwork.
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
The app page containing the Comic Home Page, favorites, history, and downloads,
with the same header and sidebar behavior as the Audio Screen. Its selected
Favorites entry shows the Local Favorite and Source Favorite choices, while
Comic Collection Layout remains shared across pages.
_Avoid_: Works Home Tab, discovery page

**Comic Details Screen (漫画详情页)**:
The page describing one comic's synopsis, tags, chapters, available source comments,
and actions.
It is distinct from the Comic Screen and Comic Reader.
Opening it from the Comic Home Page shows the current Comic Source catalog.
Downloaded chapters remain readable if the Comic Source is unavailable.
Opening it from Downloaded or its search shows only chapters downloaded in full.
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

**Comic Home Page (漫画主页)**:
The Comic Screen page opened by selecting a source, showing recommendations and
categories for the selected enabled Comic Source, independent of the favorite collection. Its
anonymous access follows the Comic Source's browsing requirements.
_Avoid_: Comic Screen, source library

**Comic Collection Layout (漫画集合布局)**:
  The card presentation shared by the Home, Favorites, History, and Downloaded
  pages: big grid, small grid with proportion-preserving covers in a denser
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

**Comic Tag (漫画标签)**:
A source-provided classification of a comic. A translated name refers to the
same Comic Tag; searches use the name supplied by the Comic Source.

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

**Update Channel (更新渠道)**:
The release family selected for Iroru update checks: Stable Release or Beta
Release.

**Stable Release (正式版)**:
A published Iroru version intended for regular use.

**Beta Release (测试版)**:
A published Iroru version intended for testing changes before a Stable Release.
_Avoid_: Development build, nightly build

**Iroru Beta**:
The Android testing edition of Iroru. It is installed alongside the stable app
and keeps separate app data.
