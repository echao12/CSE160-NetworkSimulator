#include "../../includes/socket.h"
#include "../../includes/packet.h"

// Configuration file of Transport
configuration TransportC{
    provides interface Transport;
}

implementation{
    components TransportP;
    Transport = TransportP;
    
    components RandomC as Random;
    TransportP.Random -> Random;
    
    //Lists
    components new ListC(socket_store_t, MAX_NUM_OF_SOCKETS) as socketListC;
    TransportP.socketList -> socketListC;

    components new HashmapC(socket_t, MAX_NUM_OF_SOCKETS) as map;
    TransportP.usedSockets -> map;

    components new ListC(pack, SOCKET_BUFFER_SIZE) as outstandingPacketsC;
    TransportP.outstandingPackets -> outstandingPacketsC;

    components new ListC(uint32_t, SOCKET_BUFFER_SIZE) as timeToResendC;
    TransportP.timeToResend -> timeToResendC;

    components new TimerMilliC() as resendTimerC;
    TransportP.resendTimer -> resendTimerC;
}