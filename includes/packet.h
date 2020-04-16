//Author: UCM ANDES Lab
//$Author: abeltran2 $
//$LastChangedBy: abeltran2 $

#ifndef PACKET_H
#define PACKET_H

#include "protocol.h"
#include "channels.h"
#include <string.h>

#define MAX_CACHE_SIZE 10
#define MAX_PACKETS_QUEUE_SIZE 255


enum{
	PACKET_HEADER_LENGTH = 8,
	PACKET_MAX_PAYLOAD_SIZE = 28 - PACKET_HEADER_LENGTH,
	MAX_TTL = 15,
	MAX_NEIGHBORS_SIZE = 25,
	MAX_SEQUENCE_NUMBER = 255
};


typedef nx_struct pack{
	nx_uint16_t dest;
	nx_uint16_t src;
	nx_uint16_t seq;		//Sequence Number
	nx_uint8_t TTL;		//Time to Live
	nx_uint8_t protocol;
	nx_uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
}pack;

enum{
	TCP_PACKET_HEADER_LENGTH = 8,
	TCP_PACKET_MAX_PAYLOAD_SIZE = PACKET_MAX_PAYLOAD_SIZE - TCP_PACKET_HEADER_LENGTH,
	SYN_FLAG_BIT = 0,//note: value is literally bit position
	ACK_FLAG_BIT = 1,
	FIN_FLAG_BIT = 2
};

typedef nx_struct tcp_pack{
	nx_uint8_t srcPort;
	nx_uint8_t destPort;
	nx_uint16_t byteSeq;//holds packet order
	nx_uint16_t acknowledgement;//holds expecting value for next packet recieved
	nx_uint8_t flags;
	nx_uint8_t advertisedWindow;
	nx_uint8_t payload[TCP_PACKET_MAX_PAYLOAD_SIZE];
}tcp_pack;

/*
 * logPack
 * 	Sends packet information to the general channel.
 * @param:
 * 		pack *input = pack to be printed.
 */
void logPack(pack *input){
	dbg(GENERAL_CHANNEL, "Src: %hhu Dest: %hhu Seq: %hhu TTL: %hhu Protocol:%hhu  Payload: %s\n",
	input->src, input->dest, input->seq, input->TTL, input->protocol, input->payload);
}

void logTCPPack(tcp_pack *input) {
	// Output TCP packet information to the transport channel
	dbg(TRANSPORT_CHANNEL, "SrcPort: %hhu DestPort: %hhu ByteSeq: %hhu Acknowledgement: %hhu Flags: %hhu AdvertisedWindow: %hhu Payload: %s\n",
	input->srcPort, input->destPort, input->byteSeq, input->acknowledgement, input->flags, input->advertisedWindow, input->payload);
}

void setFlagBit(tcp_pack *package, nx_uint8_t i) {
	// Turn on the i-th bit of flags
	package->flags |= (1 << i);
}

bool checkFlagBit(tcp_pack *package, nx_uint8_t i) {
	// Check whether the i-th bit of flags is on
	return package->flags & (1 << i);
}

/*
 * samePack
 * 	Check whether two packets are the same.
 * @param:
 * 		pack *P1 = the first packet.
 *		pack *P2 = the second packet.
 */
bool samePack(pack P1, pack P2) {
	return (P1.src == P2.src) && (P1.dest == P2.dest) && (P1.protocol == P2.protocol) && (strcmp(P1.payload, P2.payload) == 0);
}

enum{
	AM_PACK=6
};

#endif
