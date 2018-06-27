[![Import](https://cdn.infobeamer.com/s/img/import.png)](https://info-beamer.com/use?url=https://github.com/info-beamer/grid-player)

# Video Wall Video/Image player

This package allows you to play back videos and images on
multiple screens. Build a giant video wall with ease.

## Configuration

Similar to other packages you can configure a playlist
consisting of images and videos. It's recommended to use the
*Asset Browser* for easy selection of assets.

In the *Layout Configuration* section you can set how many
screens your video wall setup consists of. You can also tell
the system if all monitors are rotated (clockwise). A setup
with 3x1 screens rotated 90 degree might look like this:

![Example](example-3x1-rotated.jpg)

Finally you must assign devices to each grid location. Click
on *Add Device*, then select the grid position (x=1, y=1 is
in the top left corner) and select the device that should
display this location.

If you have multiple video walls that should display the
same content, you can also assign multiple devices to the
same grid position.

## Stream

This package as experimental support for live streaming.
Just enter a stream url and your device will play that
stream instead of the configured playlist.

Since there is no communication across devices running
a video wall setup, synchronization is tricky. Right now
streaming really only works if you configure a RTP multicast
stream. You can use the "Multicast Video Streamer" to
generate such a stream from a connected camera module. Learn more about the package at
https://info-beamer.com/pkg/7314

## Standalone usage

Have a look at the included [STANDALONE.md](STANDALONE.md)
file to read more about how you can use this package outside
of info-beamer hosted.

## Version 3.0

 * Added support for multicast streaming.
