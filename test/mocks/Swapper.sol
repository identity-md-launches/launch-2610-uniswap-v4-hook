// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Prefunded, controller-only LOCAL harness. Not a production router or LP custodian.
contract Swapper is IUnlockCallback {
    IPoolManager private immutable manager;
    address private immutable controller;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amount) external returns (BalanceDelta) {
        require(msg.sender == controller, "not controller");
        require(amount <= uint256(type(int256).max), "amount overflow");
        return _swap(key, zeroForOne, -int256(amount));
    }

    function swapSpecified(PoolKey memory key, bool zeroForOne, int256 amount)
        external
        returns (BalanceDelta)
    {
        require(msg.sender == controller, "not controller");
        return _swap(key, zeroForOne, amount);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amount) private returns (BalanceDelta) {
        SwapParams memory params = SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        return abi.decode(manager.unlock(abi.encode(true, key, abi.encode(params))), (BalanceDelta));
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity)
        external
        returns (BalanceDelta)
    {
        require(msg.sender == controller, "not controller");
        ModifyLiquidityParams memory params = ModifyLiquidityParams(lower, upper, liquidity, bytes32(0));
        return abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (bool isSwap, PoolKey memory key, bytes memory params) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (isSwap) {
            delta = manager.swap(key, abi.decode(params, (SwapParams)), "");
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        }
        settle(key.currency0, delta.amount0());
        settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(-int256(amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), owed), "transfer failed");
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint128(amount));
        }
    }

    receive() external payable {}
}
