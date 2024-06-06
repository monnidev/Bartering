/*
TO DO
- Security check for transfers
- Evaluate additions
- Add the possibility to make proposals
- Evaluate the addition of ERC1155
*/

// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.26;

// Imports
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "../lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

// Error declarations
error Bartering__IncorrectFee();
error Bartering__LengthMismatch();
error Bartering__NotZero();
error Bartering__UnknownType();
error Bartering__OnlyRequester();
error Bartering__RequestNotPending();
error Bartering__NothingToWithdraw();
error Bartering__TokenDoesNotExist();
error Bartering__ProposalRequestLengthMismatch();
error Bartering__RequestNotActive();
error Bartering__ProposalNotValid();
error Bartering__IndicesCannotBeEmpty();
error Bartering__DuplicateOrUnsortedIndices();
error Bartering_OwnerWithdrawalFailed();

/**
 * @title Bartering
 * @dev A contract to facilitate bartering of ERC20 and ERC721 tokens between users.
 */
contract Bartering is ReentrancyGuard, Ownable {
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
        TokenDetail[] offeredItems; // List of items offered by the requester
        TokenDetail[] requestedItems; // List of items requested from the other party
        RequestStatus status; // Status of the request (Pending, Completed, Cancelled)
    }

    // State variables
    mapping(uint256 => BarterRequest) private s_barterRequests; // Maps request IDs to barter requests
    mapping(address => uint256[]) private s_userRequests; // Maps user addresses to their request IDs
    uint256 private s_nextRequestId; // Next request ID to be used, starts at 0
    mapping(address => TokenDetail[]) private s_withdrawableTokens; // Tokens withdrawable by address

    uint256 s_currentFee;
    uint256 s_balance;

    // Events
    event BarterRequestCreated(uint256 indexed requestId, address indexed requester);
    event BarterRequestCancelled(uint256 indexed requestId, address indexed requester);
    event BarterRequestAccepted(uint256 indexed requestId, address indexed accepter);
    event TokensWithdrawn(address indexed user, uint256 length);
    event TokensTransferredFromUser(address indexed user, uint256 length);
    event TokensMovedToWithdrawable(address indexed user, uint256 length);

    /**
     * @dev Constructor to initialize the contract with the initial owner.
     * @param initialOwner The address of the initial owner.
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        s_nextRequestId = 0;
        s_currentFee = 0;
    }

    /**
     * @notice Creates a new barter request.
     * @dev For ERC721 tokens, a token ID of `type(uint256).max` is considered as accepting any token from the collection.
     * @param offeredTokenTypes Types of the tokens being offered.
     * @param offeredTokenAddresses Addresses of the tokens being offered.
     * @param offeredTokenIds IDs of the tokens being offered.
     * @param offeredAmounts Amounts of the tokens being offered.
     * @param requestedTokenTypes Types of the tokens being requested.
     * @param requestedTokenAddresses Addresses of the tokens being requested.
     * @param requestedTokenIds IDs of the tokens being requested.
     * @param requestedAmounts Amounts of the tokens being requested.
     * @return The ID of the newly created request.
     */
    function createBarterRequest(
        uint8[] memory offeredTokenTypes,
        address[] memory offeredTokenAddresses,
        uint256[] memory offeredTokenIds,
        uint256[] memory offeredAmounts,
        uint8[] memory requestedTokenTypes,
        address[] memory requestedTokenAddresses,
        uint256[] memory requestedTokenIds,
        uint256[] memory requestedAmounts
    ) external payable nonReentrant returns (uint256) {
        require(msg.value == s_currentFee, Bartering__IncorrectFee());
        s_balance += msg.value;

        // Check if input arrays have matching lengths
        uint256 offeredLength =
            _checkArrayLengths(offeredTokenTypes, offeredTokenAddresses, offeredTokenIds, offeredAmounts);
        uint256 requestedLength =
            _checkArrayLengths(requestedTokenTypes, requestedTokenAddresses, requestedTokenIds, requestedAmounts);

        // Convert input arrays to TokenDetail arrays
        TokenDetail[] memory offeredItems = _convertToTokenDetailArray(
            offeredLength, offeredTokenTypes, offeredTokenAddresses, offeredTokenIds, offeredAmounts
        );
        TokenDetail[] memory requestedItems = _convertToTokenDetailArray(
            requestedLength, requestedTokenTypes, requestedTokenAddresses, requestedTokenIds, requestedAmounts
        );

        // Transfer offered tokens from the user to the contract
        _transferTokensFromUser(offeredLength, offeredItems);

        // Create a new barter request
        uint256 requestId = s_nextRequestId;
        s_barterRequests[requestId] = BarterRequest({
            requester: msg.sender,
            offeredItems: offeredItems,
            requestedItems: requestedItems,
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
     * @param proposedTokenTypes Types of the proposed tokens.
     * @param proposedTokenAddresses Addresses of the proposed tokens.
     * @param proposedTokenIds IDs of the proposed tokens.
     * @param proposedAmounts Amounts of the proposed tokens.
     */
    function acceptBarterRequest(
        uint256 requestId,
        uint8[] memory proposedTokenTypes,
        address[] memory proposedTokenAddresses,
        uint256[] memory proposedTokenIds,
        uint256[] memory proposedAmounts
    ) external nonReentrant {
        // Check if input arrays have matching lengths
        uint256 arrayLength =
            _checkArrayLengths(proposedTokenTypes, proposedTokenAddresses, proposedTokenIds, proposedAmounts);

        // Convert input arrays to TokenDetail arrays
        TokenDetail[] memory proposedTokens = _convertToTokenDetailArray(
            arrayLength, proposedTokenTypes, proposedTokenAddresses, proposedTokenIds, proposedAmounts
        );

        // Validate the proposed tokens against the request
        require(_isValidProposal(requestId, proposedTokens), Bartering__ProposalNotValid());

        // Transfer proposed tokens from the user to the contract
        _transferTokensFromUser(arrayLength, proposedTokens);

        // Retrieve the current request and update its status to completed
        BarterRequest memory currentRequest = s_barterRequests[requestId];
        s_barterRequests[requestId].status = RequestStatus.Completed;

        // Move the tokens to the withdrawable state for both parties
        _moveTokensToWithdrawable(currentRequest.requester, proposedTokens);
        _moveTokensToWithdrawable(msg.sender, currentRequest.requestedItems);

        // Emit event for the accepted barter request
        emit BarterRequestAccepted(requestId, msg.sender);
    }

    /**
     * @notice Withdraws all tokens for the caller.
     * @dev This can be problematic if the tokens have non-standard implementations.
     */
    function withdrawAllTokens() external nonReentrant {
        // Retrieve the tokens to withdraw for the caller
        TokenDetail[] memory tokensToWithdraw = s_withdrawableTokens[msg.sender];
        uint256 length = tokensToWithdraw.length;

        // Ensure there are tokens to withdraw
        require(length != 0, Bartering__NothingToWithdraw());

        // Clear the withdrawable tokens for the caller
        delete s_withdrawableTokens[msg.sender];

        // Withdraw the tokens
        _withdrawTokens(length, tokensToWithdraw);

        // Emit event for the withdrawn tokens
        emit TokensWithdrawn(msg.sender, length);
    }

    function withdrawTokensByIndices(uint256[] memory indices) external nonReentrant {
        uint256 arrayLength = s_withdrawableTokens[msg.sender].length;
        uint256 indicesLength = indices.length;

        // Ensure indices are within bounds, unique and sorted
        require(indicesLength > 0, Bartering__IndicesCannotBeEmpty());
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
        _withdrawTokens(indicesLength, tokensToWithdraw);

        // Remove withdrawn tokens from storage, ensuring array integrity
        for (uint256 i = 0; i < indicesLength; i++) {
            uint256 lastIndex = arrayLength - 1 - i;
            uint256 index = indices[indicesLength - 1 - i]; // Adjust index for each removal
            if (index != lastIndex) {
                s_withdrawableTokens[msg.sender][index] = s_withdrawableTokens[msg.sender][lastIndex];
            }
            s_withdrawableTokens[msg.sender].pop();
        }

        // Emit event for the withdrawn tokens
        emit TokensWithdrawn(msg.sender, indicesLength);
    }

    function changeFee(uint256 newFee) external onlyOwner {
        s_currentFee = newFee;
    }

    function ownerWithdrawal(address receiver) external onlyOwner {
        uint256 toWithdraw = s_balance;
        s_balance = 0;
        (bool success,) = payable(receiver).call{value: toWithdraw}("");
        if (!success) {
            revert Bartering_OwnerWithdrawalFailed();
        }
    }

    /**
     * @dev Validates a proposed barter against a request.
     * @param proposalId The ID of the request.
     * @param proposedTokens The proposed tokens.
     * @return bool indicating whether the proposal is valid.
     * @dev For ERC721 tokens, a token ID of `type(uint256).max` is considered as accepting any token from the collection.
     */
    function _isValidProposal(uint256 proposalId, TokenDetail[] memory proposedTokens) private view returns (bool) {
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
     * @param length The number of tokens.
     * @param tokenDetails The token details.
     */
    function _transferTokensFromUser(uint256 length, TokenDetail[] memory tokenDetails) private {
        for (uint256 i = 0; i < length; i++) {
            TokenType currentType = tokenDetails[i].tokenType;
            if (currentType == TokenType.ERC20) {
                // Transfer ERC20 token from user to contract without checking return value
                IERC20(tokenDetails[i].tokenAddress).transferFrom(msg.sender, address(this), tokenDetails[i].amount);
            } else if (currentType == TokenType.ERC721) {
                // Transfer ERC721 token from user to contract
                IERC721(tokenDetails[i].tokenAddress).transferFrom(msg.sender, address(this), tokenDetails[i].tokenId);
            }
        }
        // Emit event for transferring tokens from the user
        emit TokensTransferredFromUser(msg.sender, length);
    }

    /**
     * @dev Withdraws tokens to the user.
     * @param length The number of tokens.
     * @param tokenDetails The token details.
     */
    function _withdrawTokens(uint256 length, TokenDetail[] memory tokenDetails) private {
        for (uint256 i = 0; i < length; i++) {
            TokenType currentType = tokenDetails[i].tokenType;
            if (currentType == TokenType.ERC20) {
                // Transfer ERC20 token from contract to user without checking return value
                IERC20(tokenDetails[i].tokenAddress).transfer(msg.sender, tokenDetails[i].amount);
            } else if (currentType == TokenType.ERC721) {
                // Transfer ERC721 token from contract to user
                IERC721(tokenDetails[i].tokenAddress).transferFrom(address(this), msg.sender, tokenDetails[i].tokenId);
            }
        }
    }

    /**
     * @dev Checks if input arrays have matching lengths.
     * @param tokenTypes Types of the tokens.
     * @param tokenAddresses Addresses of the tokens.
     * @param tokenIds IDs of the tokens.
     * @param amounts Amounts of the tokens.
     * @return The length of the input arrays.
     */
    function _checkArrayLengths(
        uint8[] memory tokenTypes,
        address[] memory tokenAddresses,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) private pure returns (uint256) {
        uint256 length = tokenTypes.length;
        if (tokenAddresses.length != length || tokenIds.length != length || amounts.length != length) {
            revert Bartering__LengthMismatch();
        }
        if (length == 0) revert Bartering__NotZero();
        return length;
    }

    /**
     * @dev Converts input arrays to an array of TokenDetail structs.
     * @param length The length of the arrays.
     * @param tokenTypes Types of the tokens.
     * @param tokenAddresses Addresses of the tokens.
     * @param tokenIds IDs of the tokens.
     * @param amounts Amounts of the tokens.
     * @return An array of TokenDetail structs.
     */
    function _convertToTokenDetailArray(
        uint256 length,
        uint8[] memory tokenTypes,
        address[] memory tokenAddresses,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) private pure returns (TokenDetail[] memory) {
        TokenDetail[] memory tokenDetails = new TokenDetail[](length);
        for (uint256 i = 0; i < length; i++) {
            uint8 currentType = tokenTypes[i];
            require(currentType < 2, Bartering__UnknownType());
            tokenDetails[i].tokenType = TokenType(currentType);
            tokenDetails[i].tokenAddress = tokenAddresses[i];
            tokenDetails[i].tokenId = tokenIds[i];
            tokenDetails[i].amount = amounts[i];
        }
        return tokenDetails;
    }

    /**
     * @notice Gets barter request details by ID.
     * @param requestId The ID of the request.
     * @return The details of the barter request.
     */
    function getBarterRequestById(uint256 requestId)
        external
        view
        returns (address, TokenDetail[] memory, TokenDetail[] memory, RequestStatus)
    {
        BarterRequest memory request = s_barterRequests[requestId];
        return (request.requester, request.offeredItems, request.requestedItems, request.status);
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

    function getCurrentFee() external view returns (uint256 currentFee) {
        return s_currentFee;
    }
}
