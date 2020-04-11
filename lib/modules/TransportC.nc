#include "../../includes/socket.h"
// Configuration file of Transport
configuration TransportC{
    provides interface Transport;
}

implementation{
    components TransportP;
    Transport = TransportP;
    components new TimerMilliC() as lTimer;
    components RandomC as Random;

    //Timers
    TransportP.listenTimer -> lTimer;
    TransportP.Random -> Random;
    //Lists
    components new ListC(socket_store_t, 10);
    TransportP.socketList -> ListC;

    components new HashmapC(socket_t, MAX_NUM_OF_SOCKETS) as map;
    TransportP.usedSockets -> map;

}