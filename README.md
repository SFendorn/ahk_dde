# ahk_dde
AHK v2 library script to enable DDE communication with other applications.

Inspired by dde.ahk provided by Joy2DWorld via AHK forums. Uses classes to allow multiple connections at once.

## How to use
Include dde.ahk in your AHK script and create an instance of the `DDE_Conversation` class. Use the class methods to interact with the DDE connection:
* Connect to a DDE Server via `Connect`
* Execute DDE commands via `Execute`
* Send DDE Requests to receive data via `Request`
* Terminate the connection via `Disconnect`

## Missing features
WM_DDE_ADVISE, 
WM_DDE_UNADVISE, 
WM_DDE_POKE
