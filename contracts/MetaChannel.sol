
pragma solidity ^0.4.23;

import "./lib/interpreters/LibInterpreterInterface.sol";
import "./CTFRegistry.sol";

/// @title SpankChain Meta-channel - An interpreter designed to handle multiple state-channels
/// @author Nathan Ginnever - <ginneversource@gmail.com>

contract MetaChannel {
    // sub-channel state
    struct SubChannel {
        uint isSubClose;
        uint isSubInSettlementState;
        uint subSequence;
        uint lockedNonce;
        bytes32 lockroot;
        address[2] participants;
        bytes32 CTFaddress;
        uint subSettlementPeriodLength;
        uint subSettlementPeriodEnd;
        bytes subState;
    }

    mapping(uint => SubChannel) subChannels;

    // meta-channel state
    address public partyA; // Address of first channel participant
    address public partyB; // Address of second channel participant
    uint public settlementPeriodLength; // How long challengers have to reply to settle engagement
    bytes32 public stateRoot; // The merkle root of all sub-channel state
    bytes32 public stateHash; // Hash of entire state
    uint public isClosed;
    bytes public state;
    uint public sequence = 0;
    // settlement state
    uint public isInSettlementState = 0; // meta channel is in settling 1: Not settling 0
    CTFRegistry public registry; // Address of the CTF registry
    uint public settlementPeriodEnd; // The time when challenges are no longer accepted after

    function InterpretMetaChannel(address _registry, address _partyA, address _partyB) {
        require(_partyA != 0x0 && _partyB != 0x0 && _registry != 0x0);
        registry = CTFRegistry(_registry);
        partyA = _partyA;
        partyB = _partyB;
    }

    // entry point for settlement of byzantine sub-channel
    function startSettleStateSubchannel(bytes _proof, bytes _state, bytes _subchannel, uint8[2] _v, bytes32[2] _r, bytes32[2] _s) public {
        // check that this state is signed
        address _partyA = _getSig(_state, _v[0], _r[0], _s[0]);
        address _partyB = _getSig(_state, _v[1], _r[1], _s[1]);

        uint _channelID = _getChannelID(_subchannel);

        // get roothash
        stateRoot = _getRoot(_state);

        require(_hasAllSigs(_partyA, _partyB));

        // sub-channel must be open
        require(subChannels[_channelID].isSubClose == 0);
        // sub-channel must not already be in a settle state, this should
        // only be called once to initiate settlement period
        require(subChannels[_channelID].isSubInSettlementState == 0);

        bytes32 _stateHash = keccak256(_subchannel);
        // do proof of inclusing in of sub-channel state in root state
        require(_isContained(_stateHash, _proof, stateRoot));

        //InterpreterInterface deployedInterpreter = InterpreterInterface(registry.resolveAddress(subChannels[_channelID].CTFaddress));
        // this interprets the agreed upon state and sets its storage (currently in both the meta and subchannel)
        //deployedInterpreter.initState(_subchannel);

        // consider running some logic on the state from the interpreter to validate 
        // the new state obeys transition rules

        subChannels[_channelID].CTFaddress = _getCTFaddress(_subchannel);

        subChannels[_channelID].isSubInSettlementState = 1;
        subChannels[_channelID].subSettlementPeriodEnd = now + subChannels[_channelID].subSettlementPeriodLength;
        stateHash = keccak256(_state);
        subChannels[_channelID].subState = _subchannel;
        state = _state;
    }

    // No need for a consensus close on the SPC since it is only instantiated in 
    // byzantine cases and just requires updating the state
    // client side (update spc bond balances, updates number of channels open, remove
    // closed channel state from total SPC state)

    // could be a case where this gets instantiated because a game went byzantine but you 
    // want to continue fast closing sub-channels against this contract. Though you
    // could just settle the sub-channels off chain until another dispute. In order to 
    // continue off chain the parties will have to update the timeout onchian with this setup

    function challengeSettleStateSubchannel(bytes _proof, bytes _state, bytes _subchannel, uint8[2] _v, bytes32[2] _r, bytes32[2] _s) public {
        // check sigs
        address _partyA = _getSig(_state, _v[0], _r[0], _s[0]);
        address _partyB = _getSig(_state, _v[1], _r[1], _s[1]);

        uint _channelID = _getChannelID(_subchannel);

        // get roothash
        stateRoot = _getRoot(_state);

        require(_hasAllSigs(_partyA, _partyB));

        require(subChannels[_channelID].isSubInSettlementState == 1);
        require(subChannels[_channelID].subSettlementPeriodEnd <= now);

        bytes32 _stateHash = keccak256(_subchannel);
        require(_isContained(_stateHash, _proof, stateRoot));

        //InterpreterInterface deployedInterpreter = InterpreterInterface(registry.resolveAddress(subChannels[_channelID].CTFaddress));
        // since the initial bytes of the state are the same in subchannel as metachannel, we could reuse the isSequenceHigher here
        require(isSequenceHigher(_subchannel, subChannels[_channelID].subSequence));
        
        // store the new sub-channel state in the interpreter
        //deployedInterpreter.initState(_subchannel);

        subChannels[_channelID].CTFaddress = _getCTFaddress(_subchannel);
        // extend the challenge time for the sub-channel
        subChannels[_channelID].subSettlementPeriodEnd = now + subChannels[_channelID].subSettlementPeriodLength;
        subChannels[_channelID].subState = _subchannel;
        state = _state;
    }

    // in the case of HTLC sub-channels, this must be called after the subchannel interpreter
    // has had enough time to play out the locked txs and update is balances
    function closeWithTimeoutSubchannel(uint _channelID) public {
        // These interpreter libraries don't need to be redeployed each time, just replace state
        // with an identifier as to which lib address to use
        LibInterpreterInterface deployedInterpreter = LibInterpreterInterface(registry.resolveAddress(subChannels[_channelID].CTFaddress));

        require(subChannels[_channelID].subSettlementPeriodEnd <= now);
        require(subChannels[_channelID].isSubClose == 0);
        require(subChannels[_channelID].isSubInSettlementState == 1);

        // this may not be needed since initState is called for every challenge
        // for htlc channels, the client just needs to be sure that for any individual
        // tx timeout, that the individual timeout is shorter than the channel timeout.

        //deployedInterpreter.finalizeState(subChannels[_channelID].subState);
        uint _length = subChannels[_channelID].subState.length;
        deployedInterpreter.delegatecall(bytes4(keccak256("finalizeState(bytes)")), bytes32(32), bytes32(_length), subChannels[_channelID].subState);

        // update the meta-channel state for balance
        // TODO: generalize this to just STATE for the msig extension to read
        // just leave the state stored in the subchannel contract, and interpret it
        // via the msig
        // put the action of reconciling subchannel state and top state bytes in the interpreter
        //balanceA += deployedInterpreter.balanceA();
        //balanceB += deployedInterpreter.balanceB();
        
        // maybe do this in the metachannel
        //_reconcileState(deployedInterpreter.getExtType());

        // GET interpreter library type
        // send funds that are now stored on the metachannel

        subChannels[_channelID].isSubClose = 1;
        subChannels[_channelID].isSubInSettlementState == 0;
    }

    // TODO: Fix this, have it just take the channel id like close, but this time for htlc it will
    // read all of these params off of the htlc state and run its inclusion proof in there.
    //function update(uint _channelID)
    //  delegate a call now to update and do all of these checks
    function updateHTLCBalances(bytes _proof, uint _channelID, uint256 _lockedNonce, uint256 _amount, bytes32 _hash, uint256 _timeout, bytes32 _secret) public returns (bool) {
        require(subChannels[_channelID].isSubInSettlementState == 0);
        require(subChannels[_channelID].isSubClose == 1);
        // require that the transaction timeout has not expired
        require(now < _timeout);
        // be sure the tx nonce lines up with the interpreters sequence
        require(_lockedNonce == subChannels[_channelID].lockedNonce);
        
        bytes32 _txHash = keccak256(_lockedNonce, _amount, _hash, _timeout);
        require(_isContained(_txHash, _proof, subChannels[_channelID].lockroot));

        // no need to refund?, just don't update the state balance

        // redeem case
        require(keccak256(_secret) == _hash);
        // assume one direction payment channel
        // TODO: Make a balances array that maps the index of the array to the sequence
        // number of the subchannel state holding the lockroot, this way balances will revert
        // and build upon the checkpointed state, resetting if a higher sequence agreement is 
        // presented. NOYE this is okay since the challenge function in the meta channel
        // calls initState again with the updated agreed balances before lockroot apply.
        // thus the balances state here would get reset if a challenge updates with a higher
        // subchannel sequence
        LibInterpreterInterface deployedInterpreter = LibInterpreterInterface(registry.resolveAddress(subChannels[_channelID].CTFaddress));
        uint _length = subChannels[_channelID].subState.length;
        deployedInterpreter.delegatecall(bytes4(keccak256("update(address, uint256)")), partyB, _amount);

        subChannels[_channelID].lockedNonce++;

        return true;
    }

    // /// --- Close Meta Channel Functions

    // function startSettle(bytes _state, uint8[2] _v, bytes32[2] _r, bytes32[2] _s) public {
    //     address _partyA = _getSig(_state, _v[0], _r[0], _s[0]);
    //     address _partyB = _getSig(_state, _v[1], _r[1], _s[1]);

    //     require(_hasAllSigs(_partyA, _partyB));

    //     _decodeState(_state);

    //     require(isClosed == 0);
    //     require(isInSettlementState == 0);

    //     state = _state;

    //     isInSettlementState = 1;
    //     settlementPeriodEnd = now + settlementPeriodLength;
    // }

    // function challengeSettle(bytes _state, uint8[2] _v, bytes32[2] _r, bytes32[2] _s) public {
    //     address _partyA = _getSig(_state, _v[0], _r[0], _s[0]);
    //     address _partyB = _getSig(_state, _v[1], _r[1], _s[1]);

    //     require(_hasAllSigs(_partyA, _partyB));

    //     // require the channel to be in a settling state
    //     _decodeState(_state);
    //     require(isInSettlementState == 1);
    //     require(settlementPeriodEnd <= now);

    //     isSequenceHigher(_state, sequence);

    //     settlementPeriodEnd = now + settlementPeriodLength;
    //     state = _state;
    //     sequence++;
    // }

    // function closeWithTimeout() public {
    //     require(settlementPeriodEnd <= now);
    //     require(isClosed == 0);
    //     require(isInSettlementState == 1);

    //     _decodeState(state);
    //     // TODO: Do same extension system here as msig so
    //     // that all remain state that hasn't been used in a subchannel may be redistributed back
    //     // to the main chain
    //     stateHash = keccak256(state);
    //     isClosed = 1;
    // }

    // Internal Functions
    function _getCTFaddress(bytes _s) public returns (bytes32 _ctf) {
        assembly {
            _ctf := mload(add(_s, 64))
        }
    }

    function _getChannelID(bytes _s) public returns (uint _id) {
        assembly {
            _id := mload(add(_s, 96))
        }
    }

    function isSequenceHigher(bytes _data, uint _nonce) public returns (bool) {
        uint isHigher1;

        assembly {
            isHigher1 := mload(add(_data, 64))
        }

        require(isHigher1 > _nonce);
        return true;
    }


    function isClose(bytes _data) public returns(bool) {
        uint _isClosed;

        assembly {
            _isClosed := mload(add(_data, 32))
        }

        require(_isClosed == 1);
        return true;
    }

    function _isContained(bytes32 _hash, bytes _proof, bytes32 _root) internal returns (bool) {
        bytes32 cursor = _hash;
        bytes32 proofElem;

        for (uint256 i=64; i<=_proof.length; i+=32) {
            assembly { proofElem := mload(add(_proof, i)) }

            if (cursor < proofElem) {
                cursor = keccak256(cursor, proofElem);
            } else {
                cursor = keccak256(proofElem, cursor);
            }
        }

        return cursor == _root;
    }

    function _hasAllSigs(address _a, address _b) internal view returns (bool) {
        require(_a == partyA && _b == partyB);

        return true;
    }

    function _getRoot(bytes _state) internal returns (bytes32 _root){
        // SPC State
        // [
        //    32 isClose
        //    64 sequence
        //    96 address 1
        //    128 address 2
        //    160 balance 1
        //    192 balance 2
        //    224 sub-channel root hash

        assembly {
            _root := mload(add(_state, 224))
        }
    }

    function _getSig(bytes _d, uint8 _v, bytes32 _r, bytes32 _s) internal pure returns(address) {
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 h = keccak256(_d);

        bytes32 prefixedHash = keccak256(prefix, h);

        address a = ecrecover(prefixedHash, _v, _r, _s);

        //address a = ECRecovery.recover(prefixedHash, _s);

        return(a);
    }

    function getSubChannel(uint _channelID)
        external
        view
        returns
    (
        uint isSubClose,
        uint isSubInSettlementState,
        uint subSequence,
        uint lockedNonce,
        bytes32 lockroot,
        address[2] participants,
        bytes32 subCTFaddress,
        uint subSettlementPeriodLength,
        uint subSettlementPeriodEnd,
        bytes subState
    ) {
        SubChannel storage g = subChannels[_channelID];
        return (
            g.isSubClose,
            g.isSubInSettlementState,
            g.subSequence,
            g.lockedNonce,
            g.lockroot,
            g.participants,
            g.CTFaddress,
            g.subSettlementPeriodLength,
            g.subSettlementPeriodEnd,
            g.subState
        );
    }
}