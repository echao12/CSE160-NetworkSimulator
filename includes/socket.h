#ifndef __SOCKET_H__
#define __SOCKET_H__

enum{
    MAX_NUM_OF_SOCKETS = 10,
    ROOT_SOCKET_ADDR = 255,
    ROOT_SOCKET_PORT = 255,
    SOCKET_BUFFER_SIZE = 128,
    NULL_SOCKET = 0, // Socket number 0 is designated as NULL, it should never be used
    RTT_ESTIMATE = 600000,  // Conservative RTT estimate
    MAX_OUTSTANDING = 200,  // Maximum number of outstanding packets
    MAX_RESEND_ATTEMPTS = 5,  // How many times to resend a packet before dropping it
    TCP_WRITE_TIMER = 500,  // Controls how frequently the application (Node) will write to the socket's send buffer
    TCP_READ_TIMER = 500,
};

enum socket_state{
    CLOSED,
    LISTEN,
    ESTABLISHED,
    SYN_SENT,
    SYN_RCVD,
    FIN_WAIT_1,
    CLOSE_WAIT,
    FIN_WAIT_2,
    LAST_ACK,
    TIME_WAIT,
};

enum buffer_state {
    TYPICAL,
    WRAP,
    FULL,
};

typedef nx_uint8_t nx_socket_port_t;
typedef uint8_t socket_port_t;

// socket_addr_t is a simplified version of an IP connection.
typedef nx_struct socket_addr_t{
    nx_socket_port_t port;
    nx_uint16_t addr;
}socket_addr_t;


// File descripter id. Each id is associated with a socket_store_t
typedef uint8_t socket_t;

// State of a socket. 
typedef struct socket_store_t{
    uint8_t flag;
    enum socket_state state;
    enum buffer_state bufferState;
    uint8_t bufferSpace;
    
    //socket_port_t src;
    socket_t fd;//socket#
    socket_addr_t src;//src socket(ID/Port)
    socket_addr_t dest;//dest socket

    // This is the sender portion.
    uint8_t sendBuff[SOCKET_BUFFER_SIZE];
    uint8_t lastWritten;
    uint8_t lastAck;
    uint8_t lastSent;

    // This is the receiver portion
    uint8_t rcvdBuff[SOCKET_BUFFER_SIZE];
    uint8_t lastRead;
    uint8_t lastRcvd;
    uint8_t nextExpected;

    uint16_t RTT;
    uint8_t effectiveWindow;
}socket_store_t;

#endif
