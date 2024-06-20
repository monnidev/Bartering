/*
TO DO
- Evaluate additions like ERC1155
- Add the option to make proposals
*/

// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.26;

// Imports
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "../lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "../lib/openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

// Error declarations
error Bartering__IncorrectFee();
error Bartering__LengthMismatch();
error Bartering__OnlyRequester();
error Bartering__RequestNotPending();
error Bartering__NothingToWithdraw();
error Bartering__TokenDoesNotExist();
error Bartering__ProposalRequestLengthMismatch();
error Bartering__ProposalNotValid();
error Bartering__DuplicateOrUnsortedIndices();
error Bartering__OwnerWithdrawalFailed();

/**
 * @title Bartering
 * @dev Facilitates bartering of ERC20 and ERC721 tokens between users.
 */
contract Bartering is ReentrancyGuard, Ownable, ERC721Holder {
    using SafeERC20 for IERC20;

    // Enum to represent the status of a request
    enum RequestStatus {
        Pending,
        Completed,
        Cancelled
    }

    // Enum to represent the type of token
    enum TokenType {
        ERC20,
        ERC721
    }

    // Struct to hold details about a token
    struct TokenDetail {
        TokenType tokenType; // Type of token (ERC20 or ERC721)
        address tokenAddress; // Address of the token contract
        uint256 tokenId; // Used only for ERC721 tokens
        uint256 amount; // Used only for ERC20 tokens
    }

    // Struct to hold details about a barter request
    struct BarterRequest {
        address requester; // The address of the person making the request
        TokenDetail[] offeredItems; // Items offered by the requester
        TokenDetail[] requestedItems; // Items requested from the other party
        RequestStatus status; // Status of the request (Pending, Completed, Cancelled)
    }

    // State variables
    mapping(uint256 => BarterRequest) private s_barterRequests; // Maps request IDs to barter requests
    mapping(address => uint256[]) private s_userRequests; // Maps user addresses to their request IDs
    mapping(address => TokenDetail[]) private s_withdrawableTokens; // Tokens withdrawable by address

    uint256 private s_nextRequestId = 0; // Next request ID to be used, starts at 0

    uint256 private s_currentFee;
    uint256 private s_balance;

    // Events
    event BarterRequestCreated(uint256 indexed requestId, address indexed requester);
    event BarterRequestCancelled(uint256 indexed requestId, address indexed requester);
    event BarterRequestAccepted(uint256 indexed requestId, address indexed accepter);
    event TokensWithdrawn(address indexed user, uint256 length);
    event TokensTransferredFromUser(address indexed user, uint256 length);
    event TokensMovedToWithdrawable(address indexed user, uint256 length);
    event FeeChanged(uint256 indexed newFee);
    event OwnerWithdrew(uint256 indexed amount);

    // Modifier to enforce fee payment
    modifier feePayment() {
        require(msg.value == s_currentFee, Bartering__IncorrectFee());
        s_balance += msg.value;
        _;
    }

    /**
     * @dev Initializes the contract with the initial owner.
     * @param initialOwner The address of the initial owner.
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        s_currentFee = 0;
    }

    /**
     * @notice Creates a new barter request.
     * @dev For ERC721 tokens, a token ID of `type(uint256).max` is considered as accepting any token from the collection.
     * @param offeredTokens Array of tokens being offered.
     * @param requestedTokens Array of tokens being requested.
     * @return The ID of the newly created request.
     */
    function createBarterRequest(TokenDetail[] calldata offeredTokens, TokenDetail[] calldata requestedTokens)
        external
        payable
        nonReentrant
        feePayment
        returns (uint256)
    {
        // Transfer offered tokens from the user to the contract
        _transferTokensFromUser(offeredTokens);

        // Create a new barter request
        uint256 requestId = s_nextRequestId;
        s_barterRequests[requestId] = BarterRequest({
            requester: msg.sender,
            offeredItems: offeredTokens,
            requestedItems: requestedTokens,
            status: RequestStatus.Pending
        });

        // Add the request ID to the user's request history
        s_userRequests[msg.sender].push(requestId);

        // Increment the next request ID
        s_nextRequestId++;

        // Emit event for the created barter request
        emit BarterRequestCreated(requestId, msg.sender);

        return requestId;
    }

    /**
     * @notice Cancels an existing barter request.
     * @param requestId The ID of the request to cancel.
     */
    function cancelBarterRequest(uint256 requestId) external {
        BarterRequest memory request = s_barterRequests[requestId];

        // Ensure the caller is the requester and the request is pending
        require(msg.sender == request.requester, Bartering__OnlyRequester());
        require(request.status == RequestStatus.Pending, Bartering__RequestNotPending());

        // Update the request status to cancelled
        s_barterRequests[requestId].status = RequestStatus.Cancelled;

        // Move offered tokens to the withdrawable state
        _moveTokensToWithdrawable(request.requester, request.offeredItems);

        // Emit event for the cancelled barter request
        emit BarterRequestCancelled(requestId, msg.sender);
    }

    /**
     * @notice Accepts a barter request by proposing tokens.
     * @param requestId The ID of the request to accept.
     * @param proposedTokens Array of proposed tokens.
     */
    function acceptBarterRequest(uint256 requestId, TokenDetail[] calldata proposedTokens) external nonReentrant {
        // Validate the proposed tokens against the request
        require(_isValidProposal(requestId, proposedTokens), Bartering__ProposalNotValid());

        // Transfer proposed tokens from the user to the contract
        _transferTokensFromUser(proposedTokens);

        // Retrieve the current request and update its status to completed
        BarterRequest memory currentRequest = s_barterRequests[requestId];
        s_barterRequests[requestId].status = RequestStatus.Completed;

        // Move the tokens to the withdrawable state for both parties
        _moveTokensToWithdrawable(currentRequest.requester, proposedTokens);
        _moveTokensToWithdrawable(msg.sender, currentRequest.offeredItems);

        // Emit event for the accepted barter request
        emit BarterRequestAccepted(requestId, msg.sender);
    }

    /**
     * @notice Withdraws specified tokens for the caller by their indices. Indices must be in ascending order.
     * @param indices Array of indices representing the tokens to withdraw.
     */
    function withdrawTokensByIndices(uint256[] calldata indices) external nonReentrant {
        uint256 arrayLength = s_withdrawableTokens[msg.sender].length;
        uint256 indicesLength = indices.length;

        // Ensure indices are within bounds, unique, and sorted
        for (uint256 i = 0; i < indicesLength; i++) {
            require(indices[i] < arrayLength, Bartering__TokenDoesNotExist());
            if (i > 0) {
                require(indices[i] > indices[i - 1], Bartering__DuplicateOrUnsortedIndices());
            }
        }

        // Array to hold tokens to be withdrawn
        TokenDetail[] memory tokensToWithdraw = new TokenDetail[](indicesLength);

        // Retrieve tokens
        for (uint256 i = 0; i < indicesLength; i++) {
            tokensToWithdraw[i] = s_withdrawableTokens[msg.sender][indices[i]];
        }

        // Withdraw tokens
        _withdrawTokens(tokensToWithdraw);

        // Remove withdrawn tokens from storage, ensuring array integrity
        for (uint256 i = indicesLength; i > 0; i--) {
            uint256 lastIndex = arrayLength - i;
            uint256 index = indices[i - 1]; // Adjust index for each removal
            if (index != lastIndex) {
                s_withdrawableTokens[msg.sender][index] = s_withdrawableTokens[msg.sender][lastIndex];
            }
            s_withdrawableTokens[msg.sender].pop();
        }

        // Emit event for the withdrawn tokens
        emit TokensWithdrawn(msg.sender, indicesLength);
    }

    /**
     * @notice Changes the fee for creating a barter request.
     * @param newFee The new fee amount.
     */
    function changeFee(uint256 newFee) external onlyOwner {
        s_currentFee = newFee;
        emit FeeChanged(newFee);
    }

    /**
     * @notice Withdraws the contract balance to the specified receiver.
     * @param receiver The address of the receiver.
     */
    function ownerWithdrawal(address receiver) external onlyOwner {
        uint256 toWithdraw = s_balance;
        s_balance = 0;
        (bool success,) = payable(receiver).call{value: toWithdraw}("");
        if (!success) {
            revert Bartering__OwnerWithdrawalFailed();
        }
        emit OwnerWithdrew(toWithdraw);
    }

    /**
     * @dev Validates a proposed barter against a request.
     * @param proposalId The ID of the request.
     * @param proposedTokens The proposed tokens.
     * @return bool indicating whether the proposal is valid.
     * @dev For ERC721 tokens, a token ID of `type(uint256).max` is considered as accepting any token from the collection.
     */
    function _isValidProposal(uint256 proposalId, TokenDetail[] calldata proposedTokens) private view returns (bool) {
        BarterRequest memory request = s_barterRequests[proposalId];
        TokenDetail[] memory requestTokens = request.requestedItems;

        // Ensure the request is pending
        require(request.status == RequestStatus.Pending, Bartering__RequestNotPending());

        // Ensure the lengths of the token arrays match
        uint256 requestLength = request.requestedItems.length;
        uint256 proposedLength = proposedTokens.length;
        require(requestLength == proposedLength, Bartering__ProposalRequestLengthMismatch());

        // Validate each token
        for (uint256 i = 0; i < requestLength; i++) {
            require(
                requestTokens[i].tokenType == proposedTokens[i].tokenType
                    && requestTokens[i].tokenAddress == proposedTokens[i].tokenAddress,
                Bartering__ProposalNotValid()
            );
            if (requestTokens[i].tokenType == TokenType.ERC20) {
                require(requestTokens[i].amount == proposedTokens[i].amount, Bartering__ProposalNotValid());
            } else if (requestTokens[i].tokenType == TokenType.ERC721) {
                if (requestTokens[i].tokenId != type(uint256).max) {
                    require(requestTokens[i].tokenId == proposedTokens[i].tokenId, Bartering__ProposalNotValid());
                }
            }
        }
        return true;
    }

    /**
     * @dev Moves tokens to the withdrawable state for a receiver.
     * @param receiver The address of the receiver.
     * @param tokens The tokens to move.
     */
    function _moveTokensToWithdrawable(address receiver, TokenDetail[] memory tokens) private {
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; i++) {
            s_withdrawableTokens[receiver].push(tokens[i]);
        }
        // Emit event for moving tokens to the withdrawable state
        emit TokensMovedToWithdrawable(receiver, length);
    }

    /**
     * @dev Transfers tokens from the user to the contract.
     * @param tokenDetails The token details.
     */
    function _transferTokensFromUser(TokenDetail[] calldata tokenDetails) private {
        uint256 length = tokenDetails.length;
        for (uint256 i = 0; i < length; i++) {
            TokenType currentType = tokenDetails[i].tokenType;
            if (currentType == TokenType.ERC20) {
                // Transfer ERC20 token from user to contract
                IERC20(tokenDetails[i].tokenAddress).safeTransferFrom(msg.sender, address(this), tokenDetails[i].amount);
            } else if (currentType == TokenType.ERC721) {
                // Transfer ERC721 token from user to contract
                IERC721(tokenDetails[i].tokenAddress).safeTransferFrom(
                    msg.sender, address(this), tokenDetails[i].tokenId
                );
            } else {
                revert(); // This revert should not be triggerable.
            }
        }
        // Emit event for transferring tokens from the user
        emit TokensTransferredFromUser(msg.sender, length);
    }

    /**
     * @dev Withdraws tokens to the user.
     * @param tokenDetails The token details.
     */
    function _withdrawTokens(TokenDetail[] memory tokenDetails) private {
        uint256 length = tokenDetails.length;
        for (uint256 i = 0; i < length; i++) {
            TokenType currentType = tokenDetails[i].tokenType;
            if (currentType == TokenType.ERC20) {
                // Transfer ERC20 token from contract to user
                IERC20(tokenDetails[i].tokenAddress).safeTransfer(msg.sender, tokenDetails[i].amount);
            } else if (currentType == TokenType.ERC721) {
                // Transfer ERC721 token from contract to user
                IERC721(tokenDetails[i].tokenAddress).safeTransferFrom(
                    address(this), msg.sender, tokenDetails[i].tokenId
                );
            } else {
                revert(); // This revert should not be triggerable.
            }
        }
    }

    /**
     * @notice Gets barter request details by ID.
     * @param requestId The ID of the request.
     * @return The details of the barter request.
     */
    function getBarterRequestById(uint256 requestId) external view returns (BarterRequest memory) {
        return s_barterRequests[requestId];
    }

    /**
     * @notice Gets the request history by user.
     * @param user The address of the user.
     * @return An array of request IDs.
     */
    function getUserRequestHistory(address user) external view returns (uint256[] memory) {
        return s_userRequests[user];
    }

    /**
     * @notice Gets the next request ID.
     * @return The next request ID.
     */
    function getNextRequestId() external view returns (uint256) {
        return s_nextRequestId;
    }

    /**
     * @notice Gets withdrawable tokens by user.
     * @param user The address of the user.
     * @return An array of TokenDetail structs.
     */
    function getWithdrawableTokens(address user) external view returns (TokenDetail[] memory) {
        return s_withdrawableTokens[user];
    }

    /**
     * @notice Gets the current fee for creating a barter request.
     * @return The current fee amount.
     */
    function getCurrentFee() external view returns (uint256) {
        return s_currentFee;
    }
}
