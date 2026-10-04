# Ryoko demo video: narration script

3:00, 1920 × 1080, 30 fps. The video has no audio: record the narration over it.
Each line starts at its timecode; the time in brackets is how long a
read at a natural pace takes (the scratch voice in `out/guide.m4a`), so
there's room to slow down. `narration.json` holds the same lines and times.

All footage is the real app on an iPhone 18 Pro simulator, driven by real
touches. The Nara picks, the two place cards and Mimo's plan are scripted for
the recording (`-RyokoDemo nara`), and Translate plays a canned coffee order,
so every take matches the script.

| Time | On screen | Narration |
| --- | --- | --- |
| 0:00 | Title: Mimo, "Ryoko", "Travel, tailored to you." The phone rises with the Map. | **0:00.6** (6 s) Welcome to Ryoko: the all-in-one travel app, tailored to you, for a smoother trip from the moment you land. |
| 0:10 | Map in Nara: Mimo picks (Nara Park, Kofuku-ji, Coffee Kan…), then search "7-eleven". | **0:09.8** (11 s) Ever felt overwhelmed finding your way around a foreign country? Say you're in Nara, Japan. Ryoko shows what's around you: temples, coffee shops and local favourites, picked for you. |
| 0:22 | The 7-Eleven's card: Look Around, then its phrases arrive. Push in on the phrases and their "because" lines. | **0:22.5** (13 s) Japan is famous for its great-value 7-Elevens. Tap one, and Ryoko writes the phrases you'll need right there: two onigiri, your usual iced coffee, and a check for peanuts, because it knows about your allergy. |
| 0:37 | Show mode: the iced coffee phrase full screen, then Flip. | **0:37.2** (6 s) Each phrase says why it's there, and opens full screen to show the staff. Flip it, and it faces them. |
| 0:44 | Me: Traveller from Canada, early bird, quiet; the peanut allergy card; diet, favourites, About me. | **0:44.8** (9 s) It all comes from your profile. In the Me tab, you set your allergies, diet and travel style, and Ryoko takes them into account everywhere. |
| 0:56 | Tap Nara Park in the picks; its card scrolls down to the Tips. Push in on the tips. | **0:56.2** (17 s) Ryoko also helps you understand where you are. Tap Nara Park, famous for its friendly, bowing deer, and Ryoko shares the customs worth knowing: bow back, hold the cracker up, and show empty hands when you're done. And keep your paper map out of reach. The deer will try. |
| 1:20 | Translate, ready (English ⇄ Chinese). Push in on the language pills. | **1:20.6** (10 s) One of the hardest parts of travel is the language barrier. So Ryoko has live, split-screen translation built in. No waiting, and no passing the phone back and forth. |
| 1:35 | Tap the mic. "Hi, what do you recommend for coffee?" → 你好，你们有什么推荐的咖啡吗？ The barista: 我们的招牌是桂花拿铁… → "Our signature is the osmanthus latte. A little sweet, very fragrant." | **1:35.6** (11 s) Say you're ordering coffee in Shanghai. You ask, "What do you recommend for coffee?" Ryoko translates as you speak, and the barista's answer comes back in English moments later. |
| 1:49 | The phone tips back flat; the app flips to face to face. Push in on the top half (Chinese, turned to face the barista), then on the English answer: "Sure, that's 28 yuan. Scan to pay, or cash?" | **1:49.8** (13 s) Lay the phone flat and the screen splits. The top half turns to face the barista, in Chinese, while your half stays in English. Each translation expands to fill the screen, large and easy to read from across the counter. |
| 2:15 | Mimo: a new chat, typing "Help me plan a 3-hour tour nearby" on the keyboard, Searching the web, the plan (Kofuku-ji → Nara Park → Todai-ji → Nakatanidou), the ticket phrase, then Show on map. | **2:15.6** (16 s) And for everything else, there's Mimo, your travel companion. Ask it anything, like, "Help me plan a 3-hour tour nearby." Mimo checks the web, builds a walking plan around where you are and what you like, adds the phrase you'll need at the gate, and puts it all on the map. |
| 2:40 | Four phones: personal phrases, local customs, split-screen translation, Mimo. Then the end card. | **2:40.6** (16 s) Travelling abroad shouldn't mean juggling maps, translators and search engines. Ryoko brings personalized phrases, local customs, split-screen translation and a travel assistant into one app, so you can explore with confidence and focus on making memories. |

## Changes from the first draft

- "Zoom in on the translation" became "each translation expands to fill the
  screen": Translate has no zoom gesture, but face to face each half shows one
  language large. The video pushes in on it.
- The convenience store and the park are both in Nara, so the map scenes are
  one place. The coffee order is in Shanghai, as in the draft.
- "Intelligent assistant" became "travel assistant" (the app's copy avoids
  "AI" and "smart"), and Mimo's example is the 3-hour tour.
