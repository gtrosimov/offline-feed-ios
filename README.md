# OfflineFeed

Native iPhone offline video player, iOS 16+. Imports user-authorized MP4/MOV/M4V video files. Local profile, metadata and media are held in Application Support on device, excluded from cloud backup. No social account credentials are used. The recommender mixes favorite creators, matching topics and new categories where the imported pool contains enough videos.

Version 1.2 removes PeerTube and shows only imported Instagram/TikTok clips explicitly marked Russian. Existing unverified clips are preserved and can be re-imported with their correct source/language; old PeerTube items can be removed from settings after confirmation. Links open official Instagram/TikTok pages or favorite creator profiles. The app does not offer automatic recommendation downloads: the platforms' public developer APIs do not provide this capability. The user saves videos with the platform's authorized download feature and batch imports them from Photos or Files. Playback uses UIKit's native interactive vertical page transition, tap-to-pause and a temporary right-side 2× hold.

Build with XcodeGen and Xcode or run the GitHub Actions workflow. The resulting IPA is unsigned and must be signed for the intended iPhone before installation. The app and build source contain no personal media or account data.
