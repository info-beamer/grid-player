Another multiscreen video/image player
======================================

This info-beamer code allows you to play a playlist
containing videos and images on multiple identical screens
that are arranged in a grid. Content will be scaled
automatically to fill the complete combined area available.

So if you provide four screens arranged in a 2x2 grid, each
of them will display a quadrant of the videos/images.

It will automatically synchronize the playback without
additional tools required. Just start info-beamer on each Pi
and all devices will start all videos/images at the same
time.

Setting up a giant video image wall will be trivial.

Configuration
=============

Setting up the playlist
-----------------------

Each device has to have the exact same playlist. The
playlist is specified in the file playlist.txt. An example
playlist (without the assets required to play it) is
provided as playlist.example.txt.

Each line in the playlist.txt file must contain a single
image/video filename and its play time in seconds. A comma
seperates the two values.

The file type is determined by the file extension. Currently
videos (mp4) and images (png/jpg) are supported.
Unrecognized file extensions will result in an error.

Make sure that you copy all referenced images and videos as
well as the playlist.txt file to all devices. The file
*must* be identical on all devices, otherwise synchonization
won't work.

Right now a playlist must contain at least two items. You
are of course free to reuse the same playlist line twice.

Setting up the screens
----------------------

info-beamer expects the file settings.json in the current
directory. An example settings file is provided in
settings.example.json. Make sure all devices use the same
settings.json file.

It must be a valid json file and should look like this:

    {
        "audio": true,
        "grid": {
            "width": 2,
            "height": 2 
        },
        "rotation": 0
    }

The grid values sets up the grid of screens. In this example
it sets up four monitors are arranged in a 2x2 grid.

If you provide a rotation value, you can specify how all
monitors are rotated. The default value is 0 which means no
rotation. Use 90 to show all content rotated clockwise, etc.

The resolution of all monitors (as well as their physical
size) must be identical. Otherwise things will probably look
wierd or wrong.

The audio boolean value decides if videos should generate
audio output. By default info-beamer uses the analog output
of the Pi.

If you want HDMI audio instead of using the analogue audio
output, set the INFOBEAMER_AUDIO_TARGET=hdmi environment
variable before starting info-beamer.

Starting Playback
=================

On each device, start info-beamer like this

INFOBEAMER_ENV_GRID_X=<x> INFOBEAMER_ENV_GRID_Y=<y> info-beamer .

where <x> and <y> is the position of the screen inside the
defined grid in settings.json. The top left screen is at
x=1, y=1.

It might take a moment before playback starts. You'll see a
countdown in the bottom left corner.

Once playback started, you can update the playlist by adding
all required assets and then replacing the playlist.txt
file. It will again take a moment before playback with the
new files starts.

For a perfectly synchronized playback, make sure that each
device has a good time source. For best results connect all
devices using Ethernet and provide a local NTP server.

Changes from the previous version
=================================

The screen.width / screen.height options in the
settings.json files have been removed as they seem rather
pointless as it doesn't make sense to use anything other
than the native resolution.
