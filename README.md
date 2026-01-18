What you need to test:
1. an apple watch that is paired to an iPhone WITH REGULAR SETUP (not family setup otherwise it won't work)
2. the paired iPhone
3. a computer
4. something to plug the paired iPhone in your computer
5. an Apple ID



To test:
1. Open your computer and install Xcode.
2. When installed create a new project in Xcode (you need an Apple ID to put in when it asks).
3. Copy and paste the code into a file called ContentView in the Xcode project
4. Get your apple watch and paired iPhone.
5. Plug the iPhone into the computer.
6. The iPhone and watch should ask you if you want to trust the computer. Click trust.
7. On the iPhone go to Settings - Privacy and Security and scroll down to the bottom. You should see developer mode click on it and turn it on (this will probably restart the iPhone).
8. Turn Developer Mode on for the watch as well: Settings - Privacy and Security and scroll down (this will probably restart the watch).
9. Look at the play button. Move your gaze across to the right until you see where you can choose your simulator. Choose your watch (you can also go to the top bar. Then look for Product - Destination and choose a your watch).
10. In the Project Navigator in Xcode click the blue project icon next to your project name 



If the watch doesn't connect with the computer:
1. Unplug iPhone
2. On the iPhone and apple watch go to Settings-Developer and clear trusted computers
3. Then in Xcode go to the top menu bar and select Window-Devices and Simulators. Double click the iPhone and apple watch and select unpair device.
4. Replug in the iPhone with the computer.
5. When the iPhone and apple watch ask "Trust this computer?" select trust and type in your passcode.
