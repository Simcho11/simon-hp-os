# The HP-OS User Guide's chapters. Run inside build.py (helpers p, ul, steps, k, keys, note, fig, table, side, h2, h3).

# ================================================================ 1 Welcome
chapter("welcome", "Welcome to HP-OS",
    "What HP-OS is, what comes with it, and how this guide is organized.",
    h2("welcome-about", "About HP-OS"),
    p("HP-OS is the operating system for your HP laptop, with editions for HP OmniBook Ultra and for Intel and AMD laptops. It pairs a calm, glass-inspired desktop "
      "with the reliability of Ubuntu&nbsp;26.04&nbsp;LTS underneath. Everything you need to start working is "
      "already set up: a web browser, Microsoft&nbsp;365, a file manager and a terminal, along with automatic "
      "software updates and support for several people sharing one device."),
    h2("welcome-included", "What’s included"),
    table(["App", "What it’s for"], [
        ["<b>Files</b>", "Browse, open, copy and organize your documents, pictures and downloads."],
        ["<b>Google Chrome</b>", "Browse the web. Chrome also runs the Microsoft&nbsp;365 apps."],
        ["<b>Microsoft&nbsp;365</b>", "Word, Excel, PowerPoint, Outlook, Teams, OneDrive, OneNote, SharePoint and 17 more Microsoft apps, ready to sign in to."],
        ["<b>Terminal</b> (Ghostty)", "A fast, modern command line for advanced tasks."],
        ["<b>HP-OS Settings</b>", "Personalize your device, manage accounts and install updates."],
        ["<b>Trash</b>", "Holds deleted items until you empty it, so you can change your mind."],
    ], "apps compact"),
    h2("welcome-guide", "Using this guide"),
    p("New device? Start with <b>Getting Started</b>. Then read <b>Getting Around</b>, even if you’ve used other computers: "
      "HP-OS adds a few handy moves of its own."),
    table(["Convention", "Meaning"], [
        [k("Super"), "The key with the Windows logo, usually between Ctrl and Alt."],
        [keys("Super+Space"), "Hold the first key(s), then press the last one."],
        ["<b>Click and hold</b>", "Press the touchpad or mouse button and keep it pressed while you do something else, such as move or scroll."],
        ["Right-click", "Click with two fingers on the touchpad, press its bottom-right corner, click the right mouse button, or touch and hold on the touchscreen."],
    ], "compact"),
)

# ================================================================ 2 Getting started
chapter("setup", "Getting Started",
    "First-time setup takes only a few minutes and makes you the device’s administrator.",
    fig("setup-hello.jpg", "First-time setup begins with Hello."),
    h2("setup-steps", "Set up your device"),
    steps("On the <b>Hello</b> screen, click <b>Get started</b>.",
          "<b>Connect to Wi-Fi.</b> Choose your network and enter its password. To continue offline, choose <b>Set up without Wi-Fi</b>; you can connect later.",
          "<b>Check for updates.</b> If you’re online, HP-OS looks for the latest version before you start. If an update is available, setup shows its size and about how long it will take, then downloads and installs it; the device restarts and setup continues automatically from the next step.",
          "<b>What’s your name?</b> Enter your full name. HP-OS suggests a username to use behind the scenes. Click <b>Change</b> if you’d like a different one (lowercase letters, numbers, hyphens and underscores).",
          "<b>Choose a picture.</b> Keep your initial, or pick one of the pictures shown. This is how you’ll appear on this device.",
          "<b>Create a password.</b> Use at least 8 characters, then type it again to verify. You’ll use it to sign in and to approve changes to the device.",
          "HP-OS prepares your desktop. When it’s ready, you’re signed in."),
    '<div class="pair">' + fig("setup-wifi.jpg", "Connect to Wi-Fi, or set up without it.", "half")
        + fig("setup-name.jpg", "The first person becomes the administrator.", "half") + "</div>",
    note("The first account created during setup is an <b>administrator</b>. Administrators can add people, "
         "install updates and reset the device. Keep your password somewhere safe."),
    h2("setup-first", "Your first few minutes"),
    ul("<b>Connect your Microsoft account</b>: open Word or Outlook from the <b>Microsoft 365</b> folder on the desktop and sign in.",
       "<b>Sign in to Chrome</b> to bring over your bookmarks and saved passwords.",
       "<b>Make it yours</b>: right-click the desktop, choose <b>Wallpaper › Change</b>, then pick an accent color in <b>Settings › Colour</b>.",
       "<b>Add the people who share this device</b> in <b>Settings › Users &amp; Accounts</b>, so everyone has their own desktop and files.",
       f"<b>Learn three shortcuts</b>: {keys('Super+Space')} opens apps, {keys('Super+S')} searches, and {keys('Super+Tab')} shows everything that’s open.",
       "<b>Take the short tour</b> in <b>Settings › Welcome</b>, which also opens this guide. A copy of this guide is on your desktop."),
)

# ================================================================ 3 Getting around
chapter("around", "Getting Around",
    "How the touchpad, mouse, touchscreen and keyboard work in HP-OS.",
    h2("around-touchpad", "Touchpad"),
    table(["To…", "Do this on the touchpad"], [
        ["Click", "Tap with one finger, or press down anywhere."],
        ["Right-click", "Tap with two fingers, or press down in the bottom-right corner."],
        ["Middle-click (open a link in a new tab, paste on Linux apps)", "Tap with three fingers."],
        ["Scroll", "Slide two fingers up or down. Content moves with your fingers, as on a phone."],
        ["Drag", "Press down and hold with one finger, then move. Or tap twice quickly and slide on the second tap."],
        ["Turn desktop pages", "On an empty part of the desktop, slide two fingers up or down. Anywhere, slide three fingers up or down."],
        ["See everything that’s open", "Swipe up with four fingers. Swipe down with four fingers to go back."],
        ["Scroll a row of tiled windows sideways", "Slide three fingers left or right."],
    ], "compact"),
    p("The touchpad ignores your palm while you type, so the pointer doesn’t jump. You can adjust pointer speed, "
      "tapping and scrolling direction in <b>Settings › Keyboard &amp; Mouse</b>. If your laptop has a <b>haptic touchpad</b>, "
      "which clicks anywhere you press, Settings also lets you choose how strongly it clicks back and how hard you press to click. "
      "HP-OS detects which kind you have and shows only the settings that apply."),
    h2("around-mouse", "Mouse"),
    p("A mouse works as you’d expect, plus a few extras that make HP-OS faster to use:"),
    table(["To…", "Do this with the mouse"], [
        ["Turn desktop pages", "Scroll the wheel over an empty part of the desktop, or hold " + k("Super") + " and scroll anywhere."],
        ["Take a window to another page", "Click and hold the window’s title bar, then scroll the wheel. Each notch moves the window, and you with it, to the page above or below. Let go to drop it there."],
        ["Take a desktop icon or widget to another page", "Click and hold it, then scroll the wheel, or hold it against the top or bottom edge of the screen until the page turns."],
        ["Move a window from anywhere inside it", "Hold " + k("Super") + " and drag with the left button."],
        ["Resize a window from anywhere inside it", "Hold " + k("Super") + " and drag with the right button."],
        ["Switch between an app’s windows", "Scroll the wheel over the app’s icon in the Dock."],
        ["Open another window of an app", "Middle-click (press the wheel) on its icon in the Dock."],
        ["Open the overview", "Push the pointer into the top-left corner of the screen."],
    ], "compact"),
    h2("around-touch", "Touchscreen"),
    table(["To…", "Do this on the screen"], [
        ["Open or select", "Tap."],
        ["Right-click", "Touch and hold until the menu appears. This works in every app."],
        ["Scroll", "Slide one finger."],
        ["Move between tiled windows", "Swipe in from the left or right edge of the screen."],
        ["Pan across tiled windows", "Slide three fingers left or right."],
    ], "compact"),
    h2("around-keyboard", "Keyboard"),
    p(f"The {k('Super')} key is your shortcut to HP-OS. The ones you’ll use most:"),
    table(["Press", "To"], [
        [keys("Super+Space"), "Open the app launcher"],
        [keys("Super+S"), "Search apps, settings and actions"],
        [keys("Super+Tab"), "See every window and page (the overview)"],
        [keys("Alt+Tab"), "Switch between recent windows. Keep holding " + k("Alt") + " and press " + k("Tab") + " again to go further back; add " + k("Shift") + " to go the other way."],
        [keys("Alt+`"), "Switch between windows of the same app"],
        [keys("Super+Q"), "Close the window"],
        [keys("Super+Alt+L"), "Lock the screen"],
        [keys("Super+Shift+/"), "Show every shortcut on screen"],
    ], "compact"),
    p("The brightness, volume and mute keys work as labelled; an indicator shows the new level. See the appendix for the full list of shortcuts."),
)

# ================================================================ 4 Signing in
chapter("signin", "Signing In, Locking and Accounts",
    "Several people can share one HP-OS device, each with their own desktop, files and settings.",
    fig("login.jpg", "The login screen. Each account brings its own wallpaper."),
    h2("signin-login", "The login screen"),
    p("The login screen shows the date and time and everyone who has an account on the device. "
      "Choose your name, type your password and press <kbd>Enter</kbd>. If you see someone else’s name, "
      "click <b>Other users</b> to return to the list."),
    ul("<b>Add user</b> (bottom left) starts setting up a new person. An administrator approves it with their password.",
       "The buttons at the bottom right put the device to sleep, restart it or shut it down. If your device has more than one keyboard layout, a keyboard button at the bottom left switches between them.",
       "As you choose an account, the background changes to that person’s wallpaper. A wallpaper appears here after its owner has signed in and out once."),
    h2("signin-lock", "The lock screen"),
    fig("lock.jpg", "When locked, HP-OS shows the time, the weather and your battery."),
    p(f"Lock your device whenever you step away: press {keys('Super+Alt+L')}, or click <b>Lock</b> in Control Center or on the Session screen. "
      "Your apps keep running. To unlock, type your password and press <kbd>Enter</kbd>. On the lock screen you can also:"),
    ul("Use the <b>keyboard</b> button in the password field to type with an on-screen keyboard.",
       "Click <b>Switch user</b> to let someone else sign in while your apps stay open, or <b>Add user</b> to set up a new person."),
    h2("signin-session", "Sleep, restart, shut down and sign out"),
    side(p("Click <b>Session</b> in Control Center to open the Session screen. It shows how long the device has been running, and offers:")
         + table(["Choice", "What happens"], [
             ["<b>Sleep</b>", "Pauses everything and saves power. Press a key or open the lid to wake."],
             ["<b>Restart</b>", "Closes everything and starts the device again."],
             ["<b>Shut Down</b>", "Closes everything and turns the device off."],
             ["<b>Lock</b>", "Locks the screen; your apps keep running."],
             ["<b>Switch User</b>", "Shows the login screen so someone else can sign in. Your apps stay open."],
             ["<b>Log Out</b>", "Closes your apps and returns to the login screen."],
         ], "compact"),
         "session.jpg", "The Session screen."),
    p("Signing out always takes you straight back to the login screen. Save your work before you restart, shut down or log out."),
    h2("signin-accounts", "Managing accounts"),
    p("Open <b>Settings › Users &amp; Accounts</b> to see everyone who uses the device. If you don’t see it in the sidebar, type <b>Users</b> in the Settings search box."),
    ul("<b>Change your name or picture</b>: select your account, then edit <b>Name and picture</b>. You can upload a photo, then rotate and crop it.",
       "<b>Add a person</b> (administrators): enter their name and a password. They can sign in right away.",
       "<b>Reset a password</b> (administrators): select the person and choose <b>Set password</b>.",
       "<b>Delete account…</b> (administrators): permanently deletes that person’s home folder and all their files."),
    table(["Account type", "Can do"], [
        ["<b>Administrator</b>", "Everything a standard user can, plus add and remove people, reset passwords, install updates and reset the device."],
        ["<b>Standard</b>", "Use apps, keep files and personalize their own desktop and settings."],
    ], "compact"),
    note("Forgot your password? Ask another administrator to reset it in <b>Users &amp; Accounts</b>. "
         "Saved website passwords may still need your old password.", "note"),
)

# ================================================================ 5 Desktop
chapter("desktop", "The Desktop",
    "Your desktop holds icons, widgets and windows, and can span as many pages as you need.",
    fig("desktop.jpg", "The HP-OS desktop: icons on the left, the Dock at the bottom, and status icons at the bottom right."),
    h2("desktop-tour", "A quick tour"),
    table(["", "Part", "What it does"], [
        ["1", "<b>Desktop icons</b>", "Files, folders and app shortcuts in your Desktop folder. The Trash lives here too."],
        ["2", "<b>Dock</b>", "Opens the app launcher and your favorite apps, and shows what’s running. See Chapter 7."],
        ["3", "<b>Status icons</b>", "Date and time, Wi-Fi, battery, sound, notifications and Control Center. See Chapter 9."],
        ["4", "<b>Page rail</b>", "Dots on the right edge show your desktop pages when there’s more than one."],
    ], "tour"),
    h2("desktop-icons", "Icons and folders"),
    p("Everything on the desktop is a real file in your <b>Desktop</b> folder, so it also appears in Files. "
      "Drag a file from Files, an email or a web page onto the desktop to put it there; a glass outline shows where it will land."),
    ul("<b>Open</b> an icon by double-clicking it.",
       "<b>Move</b> an icon by dragging it. It settles smoothly into the nearest free spot on the grid.",
       "<b>Select several</b>: drag a box around them on an empty part of the desktop, or <kbd>Ctrl</kbd>-click each one. Drag any of them to move them all, or right-click for <b>Open</b> and <b>Move to Trash</b> for the whole group.",
       "<b>Make a folder</b>: right-click an empty part of the desktop and choose <b>New Folder</b>. It appears where you clicked, ready for you to type a name.",
       "<b>Drop onto a folder</b> to move items into it. Hold an item over a folder for a moment and the folder opens in Files."),
    h3("An icon’s right-click menu"),
    table(["Choice", "What it does"], [
        ["<b>Open</b>", "Opens the item."],
        ["<b>Set as Wallpaper</b>", "Pictures only. Makes the picture your wallpaper; HP-OS keeps a copy in Pictures › Wallpapers."],
        ["<b>Rename</b>", "Type a new name and press Enter. The file itself is renamed."],
        ["<b>Lock / Unlock</b>", "A locked icon can’t be moved or deleted by accident."],
        ["<b>Promote to front</b>", "Brings an icon in front of others that overlap it."],
        ["<b>Move to Trash</b>", "Sends the file to the Trash. <b>Undo remove</b> brings it back."],
    ], "compact"),
    side(p("Right-click an empty part of the desktop for quick actions:")
         + ul("<b>New Folder</b>", "<b>Wallpaper</b>: change it, or shuffle to the next one", "<b>Edit widgets</b>",
              "<b>Customize HP-OS</b>", "<b>Screenshot</b> and <b>Terminal</b>", "<b>Settings</b>",
              "<b>Restart shell</b>, which refreshes the desktop if it ever stops responding; your apps keep running",
              "<b>Add status icon…</b>, which adds an icon such as Weather or Bluetooth beside the clock"),
         "menu.jpg", "The desktop menu."),
    h2("desktop-pages", "Desktop pages"),
    p("When one desktop isn’t enough, HP-OS gives you more pages, stacked one above the other. Each page has its own "
      "icons, widgets and windows, so you can keep work, personal and project spaces apart."),
    table(["To…", "Do this"], [
        ["Go to the page above or below", f"Scroll or slide two fingers on an empty part of the desktop; slide three fingers anywhere; hold {k('Super')} and scroll; or press {keys('Super+Page_Up')} / {keys('Super+Page_Down')}."],
        ["Jump to a page", f"Click its dot on the page rail, drag along the rail, or press {k('Super')} and the page number."],
        ["See every page", f"Press {keys('Super+Tab')}, swipe up with four fingers, or push the pointer into the top-left corner."],
        ["Add a page", "In the overview, click <b>+</b> below the last page. There’s also always one empty page waiting at the end."],
        ["Close a page", "In the overview, click the <b>×</b> on that page. Its icons, widgets and windows glide to the page above."],
        ["Move a window to another page", f"Click and hold its title bar and scroll; drag it to another page in the overview; or press {keys('Super+Ctrl+Page_Up')} / {keys('Super+Ctrl+Page_Down')}."],
        ["Move an icon or widget to another page", "Click and hold it and scroll, or hold it against the top or bottom edge of the screen."],
    ], "compact"),
    p("Empty pages at the end tidy themselves away automatically, and the rail shrinks to match. Empty pages between pages you’re using stay where they are. "
      "The first page is always first and can’t be closed."),
    h2("desktop-widgets", "Widgets"),
    fig("widgets.jpg", "Edit widgets shows the widget library. Your windows step aside until you click Done."),
    p("Widgets show useful information right on your desktop. The library includes a clock, world clocks, weather, calendar, "
      "notes, a to-do list, timers, media controls, a visualizer, battery and system status, pictures and an image converter."),
    steps("Right-click the desktop and choose <b>Edit widgets</b>. The windows on this page tuck into the Dock so you can see the desktop; nothing is closed.",
          "Click <b>Add widgets</b> to open the widget library. Search it, or browse <b>All</b>, <b>Active</b> and <b>Locked</b>, then click <b>+</b> to add a widget to this page.",
          "Drag widgets to arrange them. Turn on <b>Grid</b> to snap them neatly into line; the arrow keys nudge the selected widget.",
          "Click a widget to change its size, style and options, or to <b>Lock</b> it in place. Drag one widget onto another to stack them in the same spot.",
          "Click <b>Done</b>. Your windows come back exactly as they were."),
    p("Outside of editing, you can still drag any unlocked widget to a new spot or to another page. Notes, To-do and "
      "Timer widgets move only while editing, so you can type in them freely."),
    h2("desktop-trash", "Trash"),
    p("Items you delete go to the Trash, which is on the desktop and in the Dock. To delete something, drag it onto either Trash icon, "
      "or right-click it and choose <b>Move to Trash</b>. To get something back, open the Trash and drag the item wherever you want it: "
      "it leaves the Trash and returns with its original name. Empty the Trash to free up space; items in an emptied Trash can’t be recovered."),
)

# ================================================================ 6 Windows
chapter("windows", "Working with Windows",
    "Move, resize and snap windows, switch between them, and keep your screen tidy.",
    h2("windows-basics", "The basics"),
    p("Every app opens in its own window with <b>minimize</b>, <b>maximize</b> and <b>close</b> buttons in the top-right corner. "
      "The window you’re using has a deeper shadow than the others."),
    table(["To…", "Do this"], [
        ["Move a window", "Drag its title bar, or hold " + k("Super") + " and drag anywhere inside it."],
        ["Resize a window", "Drag any edge or corner, or hold " + k("Super") + " and drag with the right mouse button."],
        ["Maximize or restore", "Double-click the title bar, click the maximize button, or press " + keys("Super+Up") + " / " + keys("Super+Down") + "."],
        ["Minimize", "Click the minimize button. The window flies into its app’s icon in the Dock; click the icon to bring it back."],
        ["Fill the screen edge to edge", keys("Super+M")],
        ["Full screen (no Dock or status icons)", keys("Super+Shift+F") + ". Press it again to leave."],
        ["Close a window", "Click its close button, or press " + keys("Super+Q") + "."],
    ], "compact"),
    h2("windows-snap", "Snapping windows into place"),
    p("Snapping arranges windows side by side without fiddly resizing. While you drag a window, HP-OS shows the places it can snap to."),
    table(["Drag the window to…", "And it fills"], [
        ["The left or right edge", "That half of the screen."],
        ["A corner", "That quarter of the screen."],
        ["The top edge", "The whole screen (maximized)."],
        ["The middle of the top edge", "Opens the <b>snap layouts</b> picker. Drop the window on the zone you want."],
    ], "compact"),
    p(f"Press {keys('Super+Z')} to open the snap layouts picker for the window you’re using. Choose from halves, top and bottom, "
      "quarters, thirds, two-thirds and one-third, and main-and-stack layouts. Click a zone, or use the arrow keys or number keys and press <kbd>Enter</kbd>."),
    p("After you snap a window, <b>Fill Assist</b> offers your other windows for the space that’s left. Click one to snap it into place. "
      "When two snapped windows share an edge, dragging that edge resizes both together."),
    h3("Snapping with the keyboard"),
    table(["Press", "To"], [
        [keys("Super+Left") + " / " + keys("Super+Right"), "Snap to the left or right half. Press again to move it to the next display, or press the opposite arrow to restore it."],
        [keys("Super+Up"), "From a half, snap to the top quarter. Otherwise, maximize."],
        [keys("Super+Down"), "From a half, snap to the bottom quarter. From maximized, restore. Otherwise, minimize."],
    ], "compact"),
    h2("windows-switch", "Switching between windows"),
    ul(f"<b>Alt+Tab</b>: hold {k('Alt')} and press {k('Tab')} to see your recent windows; keep pressing {k('Tab')} to move along, and let go to switch. {keys('Alt+`')} does the same for one app’s windows.",
       "<b>Click an app in the Dock</b>. If it has several windows, HP-OS shows them so you can pick one; hovering shows previews.",
       "<b>Scroll over an app’s Dock icon</b> to step through its windows.",
       f"<b>The overview</b> ({keys('Super+Tab')}) shows every window on every page. Click one to go to it, or drag it onto another page."),
    h2("windows-float", "Floating and tiled windows"),
    p("Windows open <b>floating</b>, like a traditional desktop: you can place them anywhere and overlap them. "
      f"If you prefer windows that line up side by side automatically, press {keys('Super+V')} to <b>tile</b> a window. Tiled windows sit in a row "
      f"that you can scroll sideways. {keys('Super+V')} again makes it float. {keys('Super+Ctrl+V')} switches every window at once."),
    table(["With tiled windows, press", "To"], [
        [keys("Super+Left") + " / " + keys("Super+Right"), "Move to the window on the left or right"],
        [keys("Super+F"), "Widen the window to fill the page"],
        [keys("Super+-") + " / " + keys("Super+="), "Make the window narrower or wider"],
        [keys("Super+R"), "Cycle through preset widths"],
        [keys("Super+C"), "Center the window"],
        [keys("Super+W"), "Show the windows in a column as tabs"],
    ], "compact"),
    h2("windows-displays", "Using more than one display"),
    p("Connect a monitor and HP-OS extends your desktop onto it. Each display has its own desktop pages. Drag a window across: it shows on both displays "
      "while it straddles them. Arrange your displays to match your desk in <b>Settings › Displays</b>; nearby edges snap together."),
    table(["Press", "To"], [
        [keys("Super+Shift+Left") + " / " + keys("Super+Shift+Right"), "Move focus to the display on the left or right"],
        [keys("Super+Shift+Ctrl+Left") + " / " + keys("Super+Shift+Ctrl+Right"), "Move the window to the display on the left or right"],
        [keys("Super+Shift+P"), "Turn the displays off until you move the pointer or press a key"],
    ], "compact"),
)

# ================================================================ 7 Dock
chapter("dock", "The Dock",
    "Your launchpad for apps, and the place minimized windows go.",
    p("The Dock sits at the bottom of the screen. On the left is the <b>app launcher</b> button. Next come your <b>kept</b> apps "
      "(Files, Trash and Settings to start with), followed by any other apps that are running. A small mark under an icon means the app is open. "
      "The Dock steps aside when a window is full screen and while you edit widgets."),
    table(["To…", "Do this"], [
        ["Open an app, or bring it forward", "Click its icon."],
        ["Choose between an app’s windows", "Click an app with several windows to see them all, or hover to see previews. Middle-click a window in the list to close it."],
        ["Step through an app’s windows", "Scroll over its icon."],
        ["Open a new window", "Middle-click the icon, or right-click it and choose <b>New window</b>."],
        ["Bring back a minimized window", "Click its app’s icon. Minimized windows are marked as <b>Minimised</b> in the app’s menu."],
        ["Keep an app in the Dock", "Right-click it while it’s running and choose <b>Keep in dock</b>."],
        ["Remove an app from the Dock", "Right-click it and choose <b>Unpin from dock</b>."],
        ["Rearrange the Dock", "Drag an icon left or right."],
        ["Open a file with an app", "Drag the file onto the app’s icon."],
        ["Delete a file", "Drag it onto the Trash icon."],
    ], "compact"),
    p("Right-click any app in the Dock for its menu: <b>New window</b>, <b>Show windows</b>, <b>Keep in dock</b> or <b>Unpin from dock</b>, "
      "<b>Close window</b> or <b>Close all windows</b>. You can change the Dock’s size and behavior in <b>Settings › Dock</b>."),
)

# ================================================================ 8 Finding things
chapter("find", "Finding Apps and Files",
    "The app launcher and Search get you anywhere in a few keystrokes.",
    fig("launcher.jpg", "The app launcher lists every app on your device."),
    h2("find-launcher", "The app launcher"),
    p(f"Click the launcher button at the left of the Dock, or press {keys('Super+Space')}. Your apps appear in a grid; "
      "start typing to narrow the list, then press <kbd>Enter</kbd> to open the first match or click any app. Press <kbd>Esc</kbd>, or click an empty area, to close it."),
    h2("find-search", "Search"),
    side(p(f"Press {keys('Super+S')} to search for apps, settings and actions. Results appear as you type; use the arrow keys and <kbd>Enter</kbd>, or click. "
           "Start with one of these characters to jump straight to a tool:")
         + table(["Type", "To use"], [
             ["<kbd>;</kbd>", "Clipboard history: everything you’ve copied recently"], ["<kbd>=</kbd>", "Calculator, e.g. <i>=12*7.5</i>"],
             ["<kbd>/</kbd>", "Actions, such as lock or change wallpaper"],
             ["<kbd>:</kbd>", "Emoji picker"], ["<kbd>?</kbd>", "Search the web"], ["<kbd>$</kbd>", "Run a command"]], "compact"),
         "search.jpg", "Search suggests apps and tools."),
    note("Search with nothing typed shows suggestions based on what you use most."),
)

# ================================================================ 9 Status, Control Center, notifications
chapter("control", "Control Center and Notifications",
    "Everything about your device’s state, one click away at the bottom right of the screen.",
    h2("control-status", "Status icons"),
    p("At the bottom right of the screen are your <b>status icons</b>: the date, the time, Wi-Fi, battery, sound, notifications and Control Center. "
      "Click one for more detail."),
    table(["Click…", "To see"], [
        ["<b>Date or time</b>", "A panel with today’s date, the weather and an hourly forecast, your account with <b>Lock</b> and power buttons, and tabs for background apps, timers and the <b>Today</b> sidebar."],
        ["<b>Wi-Fi</b>", "Nearby networks. Click one to join it; <b>Details</b> shows more about your connection."],
        ["<b>Battery</b>", "Control Center, with brightness and power mode."],
        ["<b>Sound</b>", "Volume and output device, and the <b>Sound mixer</b> to set each app’s volume."],
        ["<b>Bell</b>", "Your notifications."],
        ["<b>Control Center</b> (sliders icon)", "Quick settings, below."],
    ], "compact"),
    p("Make the status icons your own: drag them to reorder, right-click one for <b>Remove bubble</b> or its settings, and right-click the desktop and choose "
      "<b>Add status icon…</b> to add Weather, Calendar, Clock, Bluetooth, Microphone, Now playing, Timers, Do Not Disturb, VPN, system Vitals and more."),
    h2("control-center", "Control Center"),
    side(table(["Control", "What it does"], [
             ["<b>Wi-Fi</b>", "Turn Wi-Fi on or off and choose a network."],
             ["<b>Bluetooth</b>", "Turn Bluetooth on or off and connect headphones, mice and other devices."],
             ["<b>Hotspot</b>", "Share your connection with other devices."],
             ["<b>VPN</b>", "Connect to a VPN you’ve set up."],
             ["<b>Media</b>", "Play, pause and skip whatever is playing."],
             ["<b>Brightness, Volume</b>", "Drag the sliders. The buttons beside them choose the display and sound output."],
             ["<b>Power mode</b>", "Choose longer battery life, Balanced, or best performance."],
             ["<b>Do Not Disturb</b>", "Silence notifications until you turn it off."],
             ["<b>Dark mode</b>", "Switch between the light and dark appearance."],
             ["<b>Night Light</b>", "Warmer colors in the evening, easier on your eyes."],
             ["<b>Microphone</b>", "Mute or unmute the microphone for every app."],
             ["<b>Keep awake</b>", "Stop the device from sleeping, for presentations or long downloads."],
             ["<b>Screen snip</b>", "Select part of the screen to capture."],
             ["<b>Lock, Settings, Session</b>", "Lock the screen, open Settings, or open the Session screen."],
         ], "compact"),
         "control.jpg", "Control Center. The pencil button customizes it."),
    h2("control-notifications", "Notifications"),
    p("When an app has something to tell you, a notification appears briefly in the corner of the screen. Click it to open the app, or move on and it "
      "waits for you under the bell. Microsoft Teams, Outlook and the other web apps notify you under their own names and icons."),
    ul("Notifications are <b>grouped by app</b>, with a count of how many each app has sent.",
       "Click <b>×</b> to dismiss one, or clear an app’s group or everything at once.",
       "Turn on <b>Do Not Disturb</b> from the notifications panel or Control Center to hold notifications until you’re ready."),
    h2("control-today", "The Today sidebar"),
    p("The Today sidebar keeps your day at a glance: a greeting, a <b>calendar</b> where you can add events, your <b>tasks</b>, quick <b>notes</b>, the "
      "<b>weather</b>, a <b>focus timer</b> with breaks, a <b>sound mixer</b> and system status. Open it from the date and time panel. "
      "Click <b>Customize panel</b> to choose its sections and their order, or <b>Keep open beside windows</b> to pin it while you work."),
)

# ================================================================ 10 Apps
chapter("apps", "Apps",
    "Getting the most from the apps that come with HP-OS.",
    h2("apps-files", "Files"),
    fig("files.jpg", "Files shows the folders in your home, with places in the sidebar and details on the right."),
    p("Files is where your documents live. The sidebar lists your folders (<b>Desktop</b>, <b>Documents</b>, <b>Downloads</b>, <b>Music</b>, <b>Pictures</b>, <b>Videos</b>), "
      "the <b>Trash</b>, and <b>Network</b> for shared folders on other computers. The path at the top shows where you are; click any part of it to go back up."),
    ul("<b>Open</b> a file by double-clicking it. Right-click for <b>Open With</b> to choose a different app.",
       "<b>Copy or move</b> by dragging. Dragging within the same drive moves the item; dragging to another drive copies it. Nothing is ever overwritten: a name already in use gets a number, such as <i>Report 2.pdf</i>.",
       "<b>Drag between</b> Files, the desktop, the Dock and other apps. A glass outline shows where the item will land.",
       "<b>Search</b> with the magnifying glass at the top right.",
       "<b>Set as Wallpaper</b>: right-click any picture.",
       "<b>Delete</b> with the <kbd>Delete</kbd> key, or drag to the Trash."),
    h2("apps-m365", "Microsoft 365"),
    p("The <b>Microsoft 365</b> folder on your desktop holds Word, Excel, PowerPoint, Outlook, Teams, OneDrive and SharePoint, "
      "and the app launcher lists all 25 Microsoft apps, including OneNote, Copilot, Forms, Planner, To Do, Loop, Whiteboard and Visio. "
      "Each runs in its own window, powered by Chrome, and appears in the Dock like any other app. The first time you open one, sign in with your work, school or personal Microsoft account; "
      "you stay signed in for the others."),
    p("Your documents are saved to OneDrive, so they’re available on your other devices too."),
    h2("apps-chrome", "Google Chrome"),
    p("Chrome is your web browser. Links you click in other apps open in Chrome. Sign in to Chrome to bring your bookmarks "
      "and passwords from your other devices. Chrome uses the graphics chip to play video smoothly while saving battery."),
    h2("apps-terminal", "Terminal"),
    p(f"Terminal (Ghostty) gives advanced users a command line. Open it from the app launcher, the desktop menu, or press {keys('Super+T')}."),
    h2("apps-screens", "Screenshots"),
    table(["To capture…", "Do this"], [
        ["An area you select", f"Press {keys('Super+Shift+4')} or <kbd>Print</kbd>, or click <b>Screen snip</b> in Control Center, then drag across the area."],
        ["The whole screen", keys("Ctrl+Print")],
        ["One window", keys("Alt+Print")],
    ], "compact"),
    p("Screenshots are copied, ready to paste into any app, and a notification confirms each one."),
)

# ================================================================ 11 Settings
chapter("settings", "Settings",
    "Personalize HP-OS and manage your device.",
    p(f"Open Settings from the Dock, the desktop menu or Control Center, or search for it with {keys('Super+S')}. "
      "Use the search box at the top of Settings to find any option by name. The arrows at the top go back and forward between pages."),
    table(["Section", "What you’ll find there"], [
        ["<b>General</b>", "Software Update, date and time, language, default apps, power options, Factory reset, About HP-OS, and Keyboard shortcuts."],
        ["<b>Appearance</b>", "Light or dark mode, and the glass look of HP-OS: solid, frosted or liquid."],
        ["<b>Colour</b>", "Your accent color. HP Blue is the default; you can also choose Teal, Green, Yellow, Orange, Red, Pink, Purple, a color taken from your wallpaper, or any custom color."],
        ["<b>Wallpaper</b>", "Choose a wallpaper or use your own pictures. The standard wallpapers, Daybreak and Harmony Night, change with light and dark mode."],
        ["<b>Dock</b>", "Which apps stay in the Dock, its size and how it behaves."],
        ["<b>Desktop</b>", "Icons, the grid, widgets and desktop pages."],
        ["<b>Notifications</b>", "Which apps can notify you, and how."],
        ["<b>Sound &amp; Feedback</b>", "Speakers, microphone, volume and system sounds."],
        ["<b>Displays</b>", "Resolution, scale, and arranging additional monitors."],
        ["<b>Keyboard &amp; Mouse</b>", "Keyboard layouts and input languages, tapping, scrolling direction and pointer speed. On laptops with a haptic touchpad (one that clicks anywhere you press), also how strongly it clicks back and how hard you press to click."],
        ["<b>Battery</b>", "Battery health, power modes and when the screen turns off."],
        ["<b>Lock Screen</b>", "When the screen locks and what it shows."],
        ["<b>Users &amp; Accounts</b>", "People, passwords and sign-in (see Chapter 4)."],
    ], "compact"),
)

# ================================================================ 12 Updates
chapter("updates", "Keeping HP-OS Up to Date",
    "HP-OS checks for updates every day and installs them safely.",
    h2("updates-check", "Checking for updates"),
    p("Your device looks for a new version of HP-OS once a day while it’s connected to the internet. When one is available, "
      "you’ll see <b>A software update is ready to install</b>. To check right away, open <b>Settings › General › Software Update</b> "
      "and click <b>Check for updates</b>."),
    h2("updates-install", "Installing an update"),
    steps("Open <b>Settings › General › Software Update</b>. You’ll see the new version, what’s new in it, how much it downloads and about how long that takes on your connection.",
          "Click <b>Update now</b> and enter an administrator’s password, then click <b>Install now</b>.",
          "HP-OS downloads and prepares the update, showing about how long is left. You can keep working while it does. Keep your device powered on.",
          "When you see <b>Ready to restart</b>, save your work and click <b>Restart now</b>, or choose <b>Later</b> and restart when it suits you."),
    note("If an update can’t be installed, your device stays on the version it had, and nothing is lost. You can try again later.", "note"),
    p("Only administrators can install updates. Standard users see <b>Ask an administrator to install this update</b>."),
    h2("updates-version", "Which version do I have?"),
    p(f"Open <b>Settings › General › Software Update</b> or <b>About HP-OS</b>. This guide describes HP-OS {VERSION}."),
)

# ================================================================ 13 Reset
chapter("reset", "Factory Reset",
    "Erase the device and start again as new, for example before giving it to someone else.",
    note("A factory reset erases <b>every account on the device</b>, with all of their files, photos and settings, along with "
         "saved Wi-Fi networks and paired Bluetooth devices. <b>This can’t be undone.</b> Back up anything you want to keep first.", "warn"),
    steps("Open <b>Settings › General</b> and choose <b>Factory reset</b>.",
          "Read what will be erased.",
          "Type your administrator password, then type it again to confirm.",
          "Click <b>Erase everything</b>. The device restarts and erases itself. This can take a few minutes; keep it powered on.",
          "When it’s done, the device opens first-time setup, just like a new device."),
    p("HP-OS itself, and any updates you’ve installed, stay on the device. Only an administrator can reset the device; "
      "if you use a standard account, ask an administrator to sign in and do it."),
)

# ================================================================ 14 Help
chapter("help", "Troubleshooting",
    "Quick fixes for common situations.",
    table(["If…", "Try this"], [
        ["The desktop stops responding, or icons look wrong", "Right-click the desktop and choose <b>Restart shell</b>. Your open apps keep running."],
        ["An app won’t respond", f"Close it with {keys('Super+Q')}, or with the × on its window, then open it again."],
        ["You can’t find a window", f"Press {keys('Super+Tab')} to see every window on every page, or click the app in the Dock. It may be minimized or on another page."],
        ["The Dock has disappeared", f"A window may be full screen. Press {keys('Super+Shift+F')}, or press {k('Esc')} in a video player."],
        ["Wi-Fi won’t connect", "Open Control Center, turn Wi-Fi off and on, then choose your network again. Check the password."],
        ["There’s no sound", "Check the volume in Control Center and the sound output button beside it. Make sure sound isn’t muted."],
        ["The touchpad doesn’t respond while typing", "That’s by design, to ignore your palm. It works again a moment after you stop typing."],
        ["You forgot your password", "Ask another administrator to reset it in <b>Settings › Users &amp; Accounts</b>."],
        ["Software Update says it couldn’t check", "Make sure you’re connected to the internet, then click <b>Check for updates</b> again."],
        ["You’re asked to restart to finish updating", "Save your work and restart. The update completes as the device starts."],
        ["Your wallpaper doesn’t appear on the login screen", "Sign out and back in once. The login screen uses the wallpaper you had when you last signed out."],
        ["The battery runs down quickly", "Choose a battery-saving <b>Power mode</b> in Control Center and turn off <b>Keep awake</b>."],
        ["Something else isn’t right", "Restart the device from the Session screen. Most problems clear after a restart."],
    ], "compact"),
    note("Install updates when they’re offered, keep your device plugged in while one installs, back up important files "
         "to OneDrive or an external drive, and lock the screen when you step away.", "tip", "Caring for your device"),
)

# ================================================================ Appendix: shortcuts
shortcut_groups = [
    ("Everyday", [
        ("Super+Space", "Open the app launcher"), ("Super+S", "Search"), ("Super+Tab", "Overview of every window and page"),
        ("Alt+Tab", "Switch between recent windows"), ("Alt+`", "Switch between one app’s windows"),
        ("Super+T", "Open Terminal"), ("Super+Alt+L", "Lock the screen"), ("Super+Shift+/", "Show all keyboard shortcuts"),
        ("Super+Shift+M", "Mute or unmute the microphone")]),
    ("Windows", [
        ("Super+Left", "Snap left"), ("Super+Right", "Snap right"), ("Super+Up", "Maximize, or snap up"),
        ("Super+Down", "Restore, snap down or minimize"), ("Super+Z", "Snap layouts"), ("Super+M", "Fill the screen edge to edge"),
        ("Super+Shift+F", "Full screen"), ("Super+V", "Float or tile the window"), ("Super+Ctrl+V", "Float or tile every window"),
        ("Super+Q", "Close the window")]),
    ("Tiled windows", [
        ("Super+F", "Widen to fill the page"), ("Super+R", "Cycle preset widths"), ("Super+C", "Center the window"),
        ("Super+-  /  Super+=", "Narrower or wider"), ("Super+W", "Show a column as tabs"),
        ("Super+Ctrl+Left  /  Super+Ctrl+Right", "Move the window left or right")]),
    ("Desktop pages", [
        ("Super+Page_Up", "Go to the page above"), ("Super+Page_Down", "Go to the page below"),
        ("Super+1 … 9", "Go to page 1 to 9"), ("!" + k("Super") + " + scroll", "Move between pages"),
        ("Super+Ctrl+Page_Up", "Move the window up a page"), ("Super+Ctrl+Page_Down", "Move the window down a page"),
        ("Super+Ctrl+1 … 9", "Move the window to page 1 to 9")]),
    ("Screenshots", [
        ("Super+Shift+4", "Copy an area"), ("Print", "Copy an area"), ("Ctrl+Print", "Copy the whole screen"),
        ("Alt+Print", "Copy one window")]),
    ("Displays", [
        ("Super+Shift+Left / Right", "Focus the display to the left or right"),
        ("Super+Shift+Ctrl+Left / Right", "Move the window to the next display"),
        ("Super+Shift+P", "Turn off the displays")]),
    ("Mouse and touchpad", [
        ("!Hold title bar + scroll", "Take the window to another page"),
        ("!" + k("Super") + " + drag", "Move a window from anywhere in it"),
        ("!" + k("Super") + " + right-drag", "Resize a window"),
        ("!Scroll on the desktop", "Turn desktop pages"),
        ("!Four-finger swipe up", "Open the overview"),
        ("!Three-finger swipe up / down", "Turn desktop pages"),
        ("!Top-left corner", "Open the overview")]),
]
