/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node -> MainC.Boot;

    Node.Receive -> GeneralReceive;

    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;

    components new SimpleSendC(AM_PACK);
    Node.Sender -> SimpleSendC;

    components CommandHandlerC;
    Node.CommandHandler -> CommandHandlerC;

    components new HashmapC(uint16_t, MAX_NEIGHBORS_SIZE) as hmap;
    Node.neighborMap -> hmap;

    components new ListC(uint16_t, MAX_CACHE_SIZE) as CacheSrcListC;
    components new ListC(uint16_t, MAX_CACHE_SIZE) as CacheSeqListC;
    Node.CacheSrc -> CacheSrcListC;
    Node.CacheSeq -> CacheSeqListC;
}
