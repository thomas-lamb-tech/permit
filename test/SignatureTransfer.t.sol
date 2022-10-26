// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {SafeERC20, IERC20, IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureVerification} from "../src/libraries/SignatureVerification.sol";
import {TokenProvider} from "./utils/TokenProvider.sol";
import {SignatureVerification} from "../src/libraries/SignatureVerification.sol";
import {PermitSignature} from "./utils/PermitSignature.sol";
import {AddressBuilder} from "./utils/AddressBuilder.sol";
import {AmountBuilder} from "./utils/AmountBuilder.sol";
import {StructBuilder} from "./utils/StructBuilder.sol";
import {Permit2} from "../src/Permit2.sol";
import {SignatureTransfer} from "../src/SignatureTransfer.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {InvalidNonce, SignatureExpired} from "../src/PermitErrors.sol";

contract SignatureTransferTest is Test, PermitSignature, TokenProvider, GasSnapshot {
    using AddressBuilder for address[];
    using AmountBuilder for uint256[];

    event InvalidateUnorderedNonces(address indexed owner, uint256 word, uint256 mask);
    event Transfer(address indexed from, address indexed token, address indexed to, uint256 amount);

    struct MockWitness {
        uint256 value;
        address person;
        bool test;
    }

    string public constant _PERMIT_TRANSFER_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(address token,address spender,uint256 signedAmount,uint256 nonce,uint256 deadline,";

    string public constant _PERMIT_BATCH_WITNESS_TRANSFER_TYPEHASH_STUB =
        "PermitBatchWitnessTransferFrom(address[] tokens,address spender,uint256[] signedAmounts,uint256 nonce,uint256 deadline,";

    string constant MOCK_WITNESS_TYPE = "MockWitness(uint256 value,address person,bool test)";
    bytes32 constant MOCK_WITNESS_TYPEHASH =
        keccak256(abi.encodePacked(_PERMIT_TRANSFER_TYPEHASH_STUB, "MockWitness", " witness)", MOCK_WITNESS_TYPE));

    bytes32 constant MOCK_BATCH_WITNESS_TYPEHASH = keccak256(
        abi.encodePacked(_PERMIT_BATCH_WITNESS_TRANSFER_TYPEHASH_STUB, "MockWitness", " witness)", MOCK_WITNESS_TYPE)
    );

    Permit2 permit2;

    address from;
    uint256 fromPrivateKey;
    uint256 defaultAmount = 1 ** 18;

    address address0 = address(0x0);
    address address2 = address(0x2);

    bytes32 DOMAIN_SEPARATOR;

    function setUp() public {
        permit2 = new Permit2();
        DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        fromPrivateKey = 0x12341234;
        from = vm.addr(fromPrivateKey);

        initializeERC20Tokens();

        setERC20TestTokens(from);
        setERC20TestTokenApprovals(vm, from, address(permit2));
    }

    function testPermitTransferFrom() public {
        uint256 nonce = 0;
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitTransfer(address(token0), nonce);
        bytes memory sig = getPermitTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address2);

        permit2.permitTransferFrom(permit, from, address2, defaultAmount, sig);

        assertEq(token0.balanceOf(from), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address2), startBalanceTo + defaultAmount);
    }

    function testPermitTransferFromToSpender() public {
        uint256 nonce = 0;
        // signed spender is address(this)
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitTransfer(address(token0), nonce);
        bytes memory sig = getPermitTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceAddr0 = token0.balanceOf(address0);
        uint256 startBalanceTo = token0.balanceOf(address(this));

        // if to is address0, tokens sent to signed spender
        permit2.permitTransferFrom(permit, from, address0, defaultAmount, sig);

        assertEq(token0.balanceOf(from), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address(this)), startBalanceTo + defaultAmount);
        // should not effect address0
        assertEq(token0.balanceOf(address0), startBalanceAddr0);
    }

    function testPermitTransferFromInvalidNonce() public {
        uint256 nonce = 0;
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitTransfer(address(token0), nonce);
        bytes memory sig = getPermitTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        permit2.permitTransferFrom(permit, from, address2, defaultAmount, sig);

        vm.expectRevert(InvalidNonce.selector);
        permit2.permitTransferFrom(permit, from, address2, defaultAmount, sig);
    }

    function testPermitTransferFromRandomNonceAndAmount(uint256 nonce, uint128 amount) public {
        token0.mint(address(from), amount);
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitTransfer(address(token0), nonce);
        permit.signedAmount = amount;
        bytes memory sig = getPermitTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address2);

        permit2.permitTransferFrom(permit, from, address2, amount, sig);

        assertEq(token0.balanceOf(from), startBalanceFrom - amount);
        assertEq(token0.balanceOf(address2), startBalanceTo + amount);
    }

    function testPermitTransferSpendLessThanFull(uint256 nonce, uint128 amount) public {
        token0.mint(address(from), amount);
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitTransfer(address(token0), nonce);
        permit.signedAmount = amount;
        bytes memory sig = getPermitTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address2);

        uint256 amountToSpend = amount / 2;
        permit2.permitTransferFrom(permit, from, address2, amountToSpend, sig);

        assertEq(token0.balanceOf(from), startBalanceFrom - amountToSpend);
        assertEq(token0.balanceOf(address2), startBalanceTo + amountToSpend);
    }

    function testPermitBatchTransferFrom() public {
        uint256 nonce = 0;
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        // address(0) gets sent to spender
        address[] memory to = AddressBuilder.fill(1, address(address2)).push(address(address0));
        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPairDifferentAddresses(defaultAmount, to);

        uint256 startBalanceFrom0 = token0.balanceOf(from);
        uint256 startBalanceFrom1 = token1.balanceOf(from);
        uint256 startBalanceTo0 = token0.balanceOf(address2);
        uint256 startBalanceTo1 = token1.balanceOf(address0);

        permit2.permitBatchTransferFrom(permit, from, toAmountPairs, sig);

        assertEq(token0.balanceOf(from), startBalanceFrom0 - defaultAmount);
        assertEq(token1.balanceOf(from), startBalanceFrom1 - defaultAmount);
        assertEq(token0.balanceOf(address2), startBalanceTo0 + defaultAmount);
        assertEq(token1.balanceOf(address0), startBalanceTo1 + defaultAmount);
    }

    function testPermitBatchTransferFromSingleRecipient() public {
        uint256 nonce = 0;
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPair(2, defaultAmount, address(address2));

        uint256 startBalanceFrom0 = token0.balanceOf(from);
        uint256 startBalanceFrom1 = token1.balanceOf(from);
        uint256 startBalanceTo0 = token0.balanceOf(address2);
        uint256 startBalanceTo1 = token1.balanceOf(address2);

        snapStart("single recipient 2 tokens");
        permit2.permitBatchTransferFrom(permit, from, toAmountPairs, sig);
        snapEnd();

        assertEq(token0.balanceOf(from), startBalanceFrom0 - defaultAmount);
        assertEq(token1.balanceOf(from), startBalanceFrom1 - defaultAmount);
        assertEq(token0.balanceOf(address2), startBalanceTo0 + defaultAmount);
        assertEq(token1.balanceOf(address2), startBalanceTo1 + defaultAmount);
    }

    function testPermitBatchTransferMultiAddr() public {
        uint256 nonce = 0;
        // signed spender is address(this)
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom0 = token0.balanceOf(from);
        uint256 startBalanceFrom1 = token1.balanceOf(from);
        uint256 startBalanceTo0 = token0.balanceOf(address(this));
        uint256 startBalanceTo1 = token1.balanceOf(address2);

        address[] memory to = AddressBuilder.fill(1, address(this)).push(address2);
        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPairDifferentAddresses(defaultAmount, to);
        permit2.permitBatchTransferFrom(permit, from, toAmountPairs, sig);

        assertEq(token0.balanceOf(from), startBalanceFrom0 - defaultAmount);
        assertEq(token0.balanceOf(address(this)), startBalanceTo0 + defaultAmount);

        assertEq(token1.balanceOf(from), startBalanceFrom1 - defaultAmount);
        assertEq(token1.balanceOf(address2), startBalanceTo1 + defaultAmount);
    }

    function testPermitBatchTransferSingleRecipientManyTokens() public {
        uint256 nonce = 0;

        address[] memory tokens = AddressBuilder.fill(10, address(token0));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom0 = token0.balanceOf(from);
        uint256 startBalanceTo0 = token0.balanceOf(address(this));

        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPair(10, defaultAmount, address(this));

        snapStart("single recipient many tokens");
        permit2.permitBatchTransferFrom(permit, from, toAmountPairs, sig);
        snapEnd();

        assertEq(token0.balanceOf(from), startBalanceFrom0 - 10 * defaultAmount);
        assertEq(token0.balanceOf(address(this)), startBalanceTo0 + 10 * defaultAmount);
    }

    function testPermitBatchTransferInvalidAmountsLengthMismatch() public {
        uint256 nonce = 0;

        address[] memory tokens = AddressBuilder.fill(2, address(token0));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPair(1, defaultAmount, address(this));

        vm.expectRevert(ISignatureTransfer.AmountsLengthMismatch.selector);
        permit2.permitBatchTransferFrom(permit, from, toAmountPairs, sig);
    }

    function testPermitBatchTransferSignedDetailsLengthMismatch() public {
        uint256 nonce = 0;

        address[] memory tokens = AddressBuilder.fill(1, address(token0));
        uint256[] memory incorrectAmounts = AmountBuilder.fill(2, 10 ** 18);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        permit.signedAmounts = incorrectAmounts;
        bytes memory sig = getPermitBatchTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPair(1, defaultAmount, address(this));

        vm.expectRevert(ISignatureTransfer.SignedDetailsLengthMismatch.selector);
        permit2.permitBatchTransferFrom(permit, from, toAmountPairs, sig);
    }

    function testGasSinglePermitTransferFrom() public {
        uint256 nonce = 0;
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitTransfer(address(token0), nonce);
        bytes memory sig = getPermitTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address2);
        snapStart("permitTransferFromSingleToken");
        permit2.permitTransferFrom(permit, from, address2, defaultAmount, sig);
        snapEnd();

        assertEq(token0.balanceOf(from), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address2), startBalanceTo + defaultAmount);
    }

    function testGasSinglePermitBatchTransferFrom() public {
        uint256 nonce = 0;
        address[] memory tokens = AddressBuilder.fill(1, address(token0));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPair(1, defaultAmount, address(address2));

        uint256 startBalanceFrom0 = token0.balanceOf(from);
        uint256 startBalanceTo0 = token0.balanceOf(address2);

        snapStart("permitBatchTransferFromSingleToken");
        permit2.permitBatchTransferFrom(permit, from, toAmountPairs, sig);
        snapEnd();

        assertEq(token0.balanceOf(from), startBalanceFrom0 - defaultAmount);
        assertEq(token0.balanceOf(address2), startBalanceTo0 + defaultAmount);
    }

    function testGasMultiplePermitBatchTransferFrom() public {
        uint256 nonce = 0;
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        address[] memory to = AddressBuilder.fill(2, address(address2)).push(address(this));
        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPairDifferentAddresses(defaultAmount, to);

        uint256 startBalanceFrom0 = token0.balanceOf(from);
        uint256 startBalanceFrom1 = token1.balanceOf(from);
        uint256 startBalanceTo0 = token0.balanceOf(address(address2));
        uint256 startBalanceTo1 = token1.balanceOf(address(address2));
        uint256 startBalanceToThis1 = token1.balanceOf(address(this));

        snapStart("permitBatchTransferFromMultipleTokens");
        permit2.permitBatchTransferFrom(permit, from, toAmountPairs, sig);
        snapEnd();

        assertEq(token0.balanceOf(from), startBalanceFrom0 - defaultAmount);
        assertEq(token0.balanceOf(address2), startBalanceTo0 + defaultAmount);
        assertEq(token1.balanceOf(from), startBalanceFrom1 - 2 * defaultAmount);
        assertEq(token1.balanceOf(address2), startBalanceTo1 + defaultAmount);
        assertEq(token1.balanceOf(address(this)), startBalanceToThis1 + defaultAmount);
    }

    function testPermitBatchTransferFromTypedWitness() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchWitnessSignature(
            permit, fromPrivateKey, MOCK_BATCH_WITNESS_TYPEHASH, witness, DOMAIN_SEPARATOR
        );

        // address(0) gets sent to spender
        address[] memory to = AddressBuilder.fill(1, address(address2)).push(address(address0));
        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPairDifferentAddresses(defaultAmount, to);

        uint256 startBalanceFrom0 = token0.balanceOf(from);
        uint256 startBalanceFrom1 = token1.balanceOf(from);
        uint256 startBalanceTo0 = token0.balanceOf(address2);
        uint256 startBalanceTo1 = token1.balanceOf(address0);

        snapStart("permitTransferFromBatchTypedWitness");
        permit2.permitBatchWitnessTransferFrom(
            permit, from, toAmountPairs, witness, "MockWitness", MOCK_WITNESS_TYPE, sig
        );
        snapEnd();

        assertEq(token0.balanceOf(from), startBalanceFrom0 - defaultAmount);
        assertEq(token1.balanceOf(from), startBalanceFrom1 - defaultAmount);
        assertEq(token0.balanceOf(address2), startBalanceTo0 + defaultAmount);
        assertEq(token1.balanceOf(address0), startBalanceTo1 + defaultAmount);
    }

    function testPermitBatchTransferFromTypedWitnessInvalidType() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchWitnessSignature(
            permit, fromPrivateKey, MOCK_BATCH_WITNESS_TYPEHASH, witness, DOMAIN_SEPARATOR
        );

        address[] memory to = AddressBuilder.fill(1, address(address2)).push(address(address0));
        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPairDifferentAddresses(defaultAmount, to);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit2.permitBatchWitnessTransferFrom(permit, from, toAmountPairs, witness, "MockWitness", "fake type", sig);
    }

    function testPermitBatchTransferFromTypedWitnessInvalidTypeName() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchWitnessSignature(
            permit, fromPrivateKey, MOCK_BATCH_WITNESS_TYPEHASH, witness, DOMAIN_SEPARATOR
        );

        address[] memory to = AddressBuilder.fill(1, address(address2)).push(address(address0));
        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPairDifferentAddresses(defaultAmount, to);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit2.permitBatchWitnessTransferFrom(
            permit, from, toAmountPairs, witness, "fake name", MOCK_WITNESS_TYPE, sig
        );
    }

    function testPermitBatchTransferFromTypedWitnessInvalidTypeHash() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig =
            getPermitBatchWitnessSignature(permit, fromPrivateKey, "fake typehash", witness, DOMAIN_SEPARATOR);

        address[] memory to = AddressBuilder.fill(1, address(address2)).push(address(address0));
        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPairDifferentAddresses(defaultAmount, to);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit2.permitBatchWitnessTransferFrom(
            permit, from, toAmountPairs, witness, "MockWitness", MOCK_WITNESS_TYPE, sig
        );
    }

    function testPermitBatchTransferFromTypedWitnessInvalidWitness() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        address[] memory tokens = AddressBuilder.fill(1, address(token0)).push(address(token1));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = defaultERC20PermitMultiple(tokens, nonce);
        bytes memory sig = getPermitBatchWitnessSignature(
            permit, fromPrivateKey, MOCK_BATCH_WITNESS_TYPEHASH, witness, DOMAIN_SEPARATOR
        );

        address[] memory to = AddressBuilder.fill(1, address(address2)).push(address(address0));
        ISignatureTransfer.ToAmountPair[] memory toAmountPairs =
            StructBuilder.fillToAmountPairDifferentAddresses(defaultAmount, to);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit2.permitBatchWitnessTransferFrom(
            permit,
            from,
            toAmountPairs,
            keccak256(abi.encodePacked("bad witness")),
            "MockWitness",
            MOCK_WITNESS_TYPE,
            sig
        );
    }

    function testInvalidateUnorderedNonces() public {
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitTransfer(address(token0), 0);
        bytes memory sig = getPermitTransferSignature(permit, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 bitmap = permit2.nonceBitmap(from, 0);
        assertEq(bitmap, 0);

        vm.prank(from);
        vm.expectEmit(true, false, false, true);
        emit InvalidateUnorderedNonces(from, 0, 1);
        permit2.invalidateUnorderedNonces(0, 1);
        bitmap = permit2.nonceBitmap(from, 0);
        assertEq(bitmap, 1);

        vm.expectRevert(InvalidNonce.selector);
        permit2.permitTransferFrom(permit, from, address2, defaultAmount, sig);
    }

    function testPermitTransferFromTypedWitness() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitWitnessTransfer(address(token0), nonce);
        bytes memory sig =
            getPermitWitnessTransferSignature(permit, fromPrivateKey, MOCK_WITNESS_TYPEHASH, witness, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address2);

        snapStart("permitTransferFromTypedWitness");
        permit2.permitWitnessTransferFrom(
            permit, from, address2, defaultAmount, witness, "MockWitness", MOCK_WITNESS_TYPE, sig
        );
        snapEnd();

        assertEq(token0.balanceOf(from), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address2), startBalanceTo + defaultAmount);
    }

    function testPermitTransferFromTypedWitnessInvalidType() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitWitnessTransfer(address(token0), nonce);
        bytes memory sig =
            getPermitWitnessTransferSignature(permit, fromPrivateKey, MOCK_WITNESS_TYPEHASH, witness, DOMAIN_SEPARATOR);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit2.permitWitnessTransferFrom(
            permit, from, address2, defaultAmount, witness, "MockWitness", "fake typedef", sig
        );
    }

    function testPermitTransferFromTypedWitnessInvalidTypehash() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitWitnessTransfer(address(token0), nonce);
        bytes memory sig =
            getPermitWitnessTransferSignature(permit, fromPrivateKey, "fake typehash", witness, DOMAIN_SEPARATOR);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit2.permitWitnessTransferFrom(
            permit, from, address2, defaultAmount, witness, "MockWitness", MOCK_WITNESS_TYPE, sig
        );
    }

    function testPermitTransferFromTypedWitnessInvalidTypeName() public {
        uint256 nonce = 0;
        MockWitness memory witnessData = MockWitness(10000000, address(5), true);
        bytes32 witness = keccak256(abi.encode(witnessData));
        ISignatureTransfer.PermitTransferFrom memory permit = defaultERC20PermitWitnessTransfer(address(token0), nonce);
        bytes memory sig =
            getPermitWitnessTransferSignature(permit, fromPrivateKey, MOCK_WITNESS_TYPEHASH, witness, DOMAIN_SEPARATOR);

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit2.permitWitnessTransferFrom(
            permit, from, address2, defaultAmount, witness, "fake name", MOCK_WITNESS_TYPE, sig
        );
    }
}
